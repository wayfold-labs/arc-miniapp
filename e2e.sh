#!/usr/bin/env bash
# Signed EURC authorization -> direct PayLink call -> browser status checks on local Arc chain id.
set -euo pipefail

# Needs Foundry (anvil, forge, cast) and a Chrome or Chromium. FOUNDRY_BIN and CHROME override what is on PATH.
if [ -n "${FOUNDRY_BIN:-}" ]; then export PATH="$FOUNDRY_BIN:$PATH"; fi
CHROME_BIN=${CHROME:-$(command -v chrome-headless-shell || command -v chromium || command -v google-chrome || true)}
[ -n "$CHROME_BIN" ] || { echo "set CHROME to a Chrome or Chromium binary" >&2; exit 2; }
CHROME_LIB=$(dirname "$CHROME_BIN")/../lib  # bundled libraries of a standalone chrome-headless-shell, if present
WORKTREE=$(cd "$(dirname "$0")" && pwd)
TEMP_DIR=$(mktemp -d)
RPC=http://127.0.0.1:18545
MNEMONIC="test test test test test test test test test test test junk"

cleanup() {
  kill $(jobs -p) 2>/dev/null || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

anvil --chain-id 5042002 --port 18545 --mnemonic "$MNEMONIC" --silent &
sleep 2
KEY=$(cast wallet private-key --mnemonic "$MNEMONIC")
PAYER=$(cast wallet address --private-key "$KEY")
cd "$WORKTREE"

TOKEN=$(forge create script/MockFiatToken.sol:MockFiatToken --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>/dev/null | awk '/Deployed to:/{print $3}')
PAYLINK=$(forge create src/PayLink.sol:PayLink --rpc-url "$RPC" --private-key "$KEY" --broadcast --constructor-args "$TOKEN" "$TOKEN" 2>/dev/null | awk '/Deployed to:/{print $3}')
echo "deployed token=$TOKEN paylink=$PAYLINK"

ID=0x$(openssl rand -hex 32)
RECIPIENT=0x2222222222222222222222222222222222222222
AMOUNT=12500000
REF=INV-1
NONCE=$(cast keccak "$(cast abi-encode 'f(bytes32,address,address,uint256,string)' "$ID" "$TOKEN" "$RECIPIENT" "$AMOUNT" "$REF")")
TIMESTAMP=$(cast block latest --field timestamp --rpc-url "$RPC")
VALID_BEFORE=$((TIMESTAMP + 3600))
TYPED_DATA=$(printf '{"types":{"EIP712Domain":[{"name":"name","type":"string"},{"name":"version","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],"ReceiveWithAuthorization":[{"name":"from","type":"address"},{"name":"to","type":"address"},{"name":"value","type":"uint256"},{"name":"validAfter","type":"uint256"},{"name":"validBefore","type":"uint256"},{"name":"nonce","type":"bytes32"}]},"primaryType":"ReceiveWithAuthorization","domain":{"name":"EURC","version":"2","chainId":5042002,"verifyingContract":"%s"},"message":{"from":"%s","to":"%s","value":"%s","validAfter":"0","validBefore":"%s","nonce":"%s"}}' "$TOKEN" "$PAYER" "$PAYLINK" "$AMOUNT" "$VALID_BEFORE" "$NONCE")
SIGNATURE=$(cast wallet sign --data "$TYPED_DATA" --private-key "$KEY")

cast send "$PAYLINK" 'payWithAuthorization(bytes32,address,address,address,uint256,string,uint256,uint256,bytes)' "$ID" "$TOKEN" "$PAYER" "$RECIPIENT" "$AMOUNT" "$REF" 0 "$VALID_BEFORE" "$SIGNATURE" --rpc-url "$RPC" --private-key "$KEY" >/dev/null
PAID_BLOCK=$(cast call "$PAYLINK" 'paidBlock(bytes32,address,address,uint256,string)(uint256)' "$ID" "$TOKEN" "$RECIPIENT" "$AMOUNT" "$REF" --rpc-url "$RPC")
echo "paidBlock=$PAID_BLOCK"
[ -n "$PAID_BLOCK" ] && [ "$PAID_BLOCK" != "0" ] && [ "$PAID_BLOCK" != "0x0" ] || {
  echo "paidBlock must be non-zero" >&2
  exit 1
}
if DUPLICATE_OUTPUT=$(cast call "$PAYLINK" 'payWithAuthorization(bytes32,address,address,address,uint256,string,uint256,uint256,bytes)' "$ID" "$TOKEN" "$PAYER" "$RECIPIENT" "$AMOUNT" "$REF" 0 "$VALID_BEFORE" "$SIGNATURE" --from "$PAYER" --rpc-url "$RPC" 2>&1); then
  echo "duplicate payment unexpectedly succeeded" >&2
  exit 1
fi
case "${DUPLICATE_OUTPUT,,}" in
  *d70a0e30*|*alreadypaid*) ;;
  *) echo "duplicate payment did not fail with AlreadyPaid: $DUPLICATE_OUTPUT" >&2; exit 1 ;;
esac

python3 - "$WORKTREE/docs/index.html" "$TEMP_DIR/index.html" "$PAYLINK" "$TOKEN" <<'PY'
import sys
source, target, paylink, token = sys.argv[1:]
page = open(source, encoding="utf-8").read()
page = page.replace('rpc: "https://rpc.testnet.arc.io"', 'rpc: "http://127.0.0.1:18545"')
page = page.replace(
    'payLink: "0x0000000000000000000000000000000000000000"',
    f'payLink: "{paylink}"',
)
page = page.replace(
    'EURC: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"',
    f'EURC: "{token}"',
)
open(target, "w", encoding="utf-8").write(page)
PY
python3 -m http.server 18099 --bind 127.0.0.1 --directory "$TEMP_DIR" >/dev/null 2>&1 &
sleep 1

CHROME_ARGS=(--headless --lang=en-US --no-first-run --no-default-browser-check --disable-extensions --no-sandbox --user-data-dir="$TEMP_DIR/profile" --virtual-time-budget=8000 --dump-dom)
show_status() {
  python3 -c 'import html,re,sys; s=sys.stdin.read(); m=re.search(r"<div id=\"chain-status\"[^>]*>(.*?)</div>",s,re.S); t=re.sub(r"<[^>]+>"," ",m.group(1)) if m else "NO STATUS"; print(" ".join(html.unescape(t).split())[:300])'
}
show_debug() {
  python3 -c 'import html,re,sys; s=sys.stdin.read(); m=re.search(r"<div id=\"debug-results\"[^>]*>(.*?)</div>",s,re.S); print(html.unescape(m.group(1)).strip() if m else "NO DEBUG RESULTS")'
}
BASE="http://127.0.0.1:18099/index.html?net=testnet&cur=EURC&id=$ID&to=$RECIPIENT&ref=$REF"
PAID_DOM=$(LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" "${CHROME_ARGS[@]}" "$BASE&amt=12.5" 2>/dev/null)
PAID_STATUS=$(printf '%s' "$PAID_DOM" | show_status)
echo "paid request   -> $PAID_STATUS"
[[ "$PAID_STATUS" == *"Paid"* && "${PAID_STATUS,,}" == *"${PAYER,,}"* ]] || {
  echo "paid page did not show Paid with payer" >&2
  exit 1
}

UNPAID_DOM=$(LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" "${CHROME_ARGS[@]}" "$BASE&amt=12" 2>/dev/null)
UNPAID_STATUS=$(printf '%s' "$UNPAID_DOM" | show_status)
echo "other amount   -> $UNPAID_STATUS"
[[ "$UNPAID_STATUS" == *"Not paid yet"* ]] || {
  echo "other-amount page did not show Not paid yet" >&2
  exit 1
}

DEBUG_DOM=$(LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" "${CHROME_ARGS[@]}" \
  "http://127.0.0.1:18099/index.html?debug=1" 2>/dev/null)
DEBUG_STATUS=$(printf '%s' "$DEBUG_DOM" | show_debug)
grep -q 'PayLink self-tests passed' <<<"$DEBUG_STATUS" || {
  echo "debug page did not report PayLink self-tests passed" >&2
  exit 1
}
if grep -q '^FAIL ' <<<"$DEBUG_STATUS"; then
  echo "debug page reported a FAIL line" >&2
  exit 1
fi
echo "self-test      -> PayLink self-tests passed"
