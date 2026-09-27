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
R=0x${SIGNATURE:2:64}
S=0x${SIGNATURE:66:64}
V_HEX=${SIGNATURE:130:2}
V=$((16#$V_HEX))
if ((V < 27)); then V=$((V + 27)); fi

cast send "$PAYLINK" 'payWithAuthorization(bytes32,address,address,address,uint256,string,uint256,uint256,uint8,bytes32,bytes32)' "$ID" "$TOKEN" "$PAYER" "$RECIPIENT" "$AMOUNT" "$REF" 0 "$VALID_BEFORE" "$V" "$R" "$S" --rpc-url "$RPC" --private-key "$KEY" >/dev/null
PAID_BLOCK=$(cast call "$PAYLINK" 'paidBlock(bytes32,address,address,uint256,string)(uint256)' "$ID" "$TOKEN" "$RECIPIENT" "$AMOUNT" "$REF" --rpc-url "$RPC")
echo "paidBlock=$PAID_BLOCK"

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

CHROME_ARGS=(--headless --no-first-run --no-default-browser-check --disable-extensions --no-sandbox --user-data-dir="$TEMP_DIR/profile" --virtual-time-budget=8000 --dump-dom)
show_status() {
  python3 -c 'import html,re,sys; s=sys.stdin.read(); m=re.search(r"<div id=\"chain-status\"[^>]*>(.*?)</div>",s,re.S); t=re.sub(r"<[^>]+>"," ",m.group(1)) if m else "NO STATUS"; print(" ".join(html.unescape(t).split())[:300])'
}
BASE="http://127.0.0.1:18099/index.html?net=testnet&cur=EURC&id=$ID&to=$RECIPIENT&ref=$REF"
echo -n "paid request   -> "
LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" "${CHROME_ARGS[@]}" "$BASE&amt=12.5" 2>/dev/null | show_status
echo -n "other amount   -> "
LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" "${CHROME_ARGS[@]}" "$BASE&amt=12" 2>/dev/null | show_status
echo -n "self-test      -> "
LD_LIBRARY_PATH="$CHROME_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$CHROME_BIN" --headless --no-sandbox --enable-logging=stderr --v=0 --virtual-time-budget=5000 "http://127.0.0.1:18099/index.html?debug=1" 2>&1 >/dev/null | grep -o -E 'PayLink self-tests passed|Self-test failed[^\"]*' | head -1
