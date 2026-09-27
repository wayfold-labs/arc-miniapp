#!/usr/bin/env bash
# Local end-to-end check of docs/index.html against anvil: deploy PayLink, pay one request with cast,
# then load the request page in an isolated headless Chrome and read the rendered status.
set -euo pipefail
export PATH=${FOUNDRY_BIN:-$HOME/.foundry/bin}:$PATH
W=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
anvil --chain-id 5042002 --port 18545 --silent & sleep 2
KEY=$(cast wallet private-key --mnemonic "test test test test test test test test test test test junk") # anvil's public dev account 0
cd "$W"
ADDR=$(forge create src/PayLink.sol:PayLink --rpc-url http://127.0.0.1:18545 --private-key "$KEY" --broadcast 2>/dev/null | awk '/Deployed to:/{print $3}')
echo "deployed $ADDR"
ID=0x$(openssl rand -hex 32); TO=0x2222222222222222222222222222222222222222
cast send "$ADDR" "pay(bytes32,address,string)" "$ID" "$TO" "INV-1" --value 12.5ether --rpc-url http://127.0.0.1:18545 --private-key "$KEY" >/dev/null
echo "paidBlock=$(cast call "$ADDR" "paidBlock(bytes32,address,uint256,string)(uint256)" "$ID" "$TO" 12500000000000000000 INV-1 --rpc-url http://127.0.0.1:18545)"
sed -e "s#https://rpc.testnet.arc.io#http://127.0.0.1:18545#" docs/index.html > "$T/index.html"
python3 - "$T/index.html" "$ADDR" <<'PY'
import sys; p, addr = sys.argv[1], sys.argv[2]; s = open(p).read()
i = s.index('testnet: {'); j = s.index('PAYLINK_ADDRESS: "0x0000000000000000000000000000000000000000"', i)
s = s[:j] + f'PAYLINK_ADDRESS: "{addr}"' + s[j + len('PAYLINK_ADDRESS: "0x0000000000000000000000000000000000000000"'):]
open(p, 'w').write(s)
PY
python3 -m http.server 18099 --bind 127.0.0.1 --directory "$T" >/dev/null 2>&1 & sleep 1
CH=(${CHROME:-google-chrome} --headless=new --no-first-run --no-default-browser-check --disable-extensions --user-data-dir="$T/profile" --virtual-time-budget=8000 --dump-dom)
show(){ python3 -c "import re,sys,html; s=sys.stdin.read(); m=re.search(r'id=\"chain-status\"[^>]*>(.*?)</div>\s*</div>', s, re.S); t=re.sub(r'<[^>]+>',' ',m.group(1)) if m else 'NO STATUS'; print(' '.join(html.unescape(t).split())[:300])"; }
echo -n "paid request   -> "; "${CH[@]}" "http://127.0.0.1:18099/index.html?net=testnet&id=$ID&to=$TO&amt=12.5&memo=INV-1" 2>/dev/null | show
echo -n "other amount   -> "; "${CH[@]}" "http://127.0.0.1:18099/index.html?net=testnet&id=$ID&to=$TO&amt=12&memo=INV-1" 2>/dev/null | show
echo -n "self-test      -> "; "${CH[@]}" --enable-logging=stderr --v=0 "http://127.0.0.1:18099/index.html?net=testnet&debug=1" 2>&1 >/dev/null | grep -o -E "PayLink self-tests passed|Self-test failed[^\"]*" | head -1
