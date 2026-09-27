# PayLink on Arc

PayLink turns a EURC or USDC invoice into a shareable link. A freelancer or small business chooses a currency,
recipient, amount and invoice reference; the payer signs a Circle EIP-3009 authorization and completes the request in
one transaction. The link is the database. Anyone who has it can verify the exact payment and download a receipt.

There is no custody, fee, approval transaction or swap. PayLink pulls the authorized amount and forwards it to the
recipient atomically, so its token balance is zero after every successful transaction.

## Why Arc

- Arc supports both Circle currencies used here: EURC for euro invoices and USDC for dollar invoices.
- USDC is Arc's native gas token, so no unrelated gas currency is needed. A EURC payer only needs a few cents of USDC
  for gas.
- Circle FiatToken v2 tokens expose EIP-3009 `receiveWithAuthorization`. The payer signs off-chain and PayLink is the
  payee that consumes the authorization, eliminating the approval transaction and preventing authorization theft.
- The Arc Memo system contract wraps the payment by default and records the invoice reference at the protocol layer.
- Arc's fast finality lets the request page show **Paid** as soon as the transaction receipt arrives.

## How it works

1. The browser creates a random 32-byte request ID and a link containing the network, currency, recipient, six-decimal
   amount and optional reference. Nothing is uploaded or stored.
2. The payer connects an injected wallet. The app reads the selected token's `name()`, `version()` and
   `DOMAIN_SEPARATOR()`, recomputes the EIP-712 domain, and refuses to sign if they do not match.
3. The wallet signs `ReceiveWithAuthorization` for PayLink, valid for one hour. Its nonce is
   `keccak256(abi.encode(id, token, recipient, amount, ref))`.
4. One transaction calls Arc Memo, which calls `payWithAuthorization`. If Memo is unavailable (for example, for a
   smart-contract wallet), the UI offers a direct PayLink transaction with the same authorization.
5. PayLink consumes the authorization, transfers the complete amount to the recipient, records the first paid block
   for the exact request and emits `Paid`.
6. Status needs one `eth_call` to locate the block, followed by a log read restricted to that one block. It never
   scans the RPC's limited log history.

## Contract interface

```solidity
constructor(address usdc, address eurc);

function payWithAuthorization(
    bytes32 id,
    address token,
    address payer,
    address recipient,
    uint256 amount,
    string ref,
    uint256 validAfter,
    uint256 validBefore,
    uint8 v,
    bytes32 r,
    bytes32 s
) external;

function paidBlock(bytes32 id, address token, address recipient, uint256 amount, string ref)
    external view returns (uint256);

event Paid(
    bytes32 indexed id,
    address indexed payer,
    address indexed recipient,
    address token,
    uint256 amount,
    string ref
);
```

`paidBlock` returns zero while unpaid and otherwise keeps the block of the first payment matching all request fields.
A second payer may pay the same link, but one payer cannot replay it because FiatToken authorization state is keyed by
that payer and the exact-request nonce.

## Security properties

- No owner, admin, upgrade path, fee logic, custody or swap logic.
- Only the immutable USDC and EURC addresses supplied at deployment are accepted.
- Zero recipients, zero amounts and references longer than 140 UTF-8 bytes are rejected.
- The nonce binds the ID, token, recipient, amount and reference. A signature cannot be repurposed for another request.
- `receiveWithAuthorization` requires its caller to be the authorized `to` address. Because `to` is PayLink, a third
  party cannot front-run the signature and redirect or consume it.
- Pull, record, event and forwarding occur in one atomic transaction. A failed token transfer reverts everything.
- The web app verifies the token's on-chain EIP-712 domain before asking the wallet to sign.

As with every irreversible payment, verify the recipient, currency, amount and reference in the wallet flow.

## Develop and test

Foundry is the only development dependency; the app itself is one static HTML file with no external assets.

```bash
# Foundry (https://getfoundry.sh) on PATH
forge build
forge test

CHROME=/path/to/chrome-or-chromium \
./e2e.sh
```

The e2e script starts anvil with Arc testnet's chain ID, deploys a local EURC-style EIP-3009 token and PayLink, signs a
real typed authorization with `cast`, pays directly (Arc Memo is not present on anvil), and asks headless Chrome to
verify paid, unpaid and in-page self-test states.

Deploy to a supported network with:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url "$ARC_RPC" --private-key "$DEPLOYER_KEY" --broadcast
```

The script selects the verified token addresses from `block.chainid` and rejects unsupported chains.

## Networks and deployments

| Network | Chain ID | RPC | Explorer | USDC ERC-20 | EURC | PayLink |
|---|---:|---|---|---|---|---|
| Arc mainnet | 5042 | `https://rpc.mainnet.arc.io` | `https://explorer.arc.io` | `0x3600000000000000000000000000000000000000` | `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` | `0x0000000000000000000000000000000000000000` |
| Arc testnet | 5042002 | `https://rpc.testnet.arc.io` | `https://explorer.testnet.arc.io` | `0x3600000000000000000000000000000000000000` | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` | `0x0000000000000000000000000000000000000000` |

The Arc Memo contract is `0x5294E9927c3306DcBaDb03fe70b92e01cCede505` on both networks. Update the two
`payLink` placeholders in the config object at the top of `docs/index.html` after deployment.

## Limits

- Arc Memo currently supports externally owned accounts only. Smart-contract wallets can use the offered direct call.
- A EURC payer still needs a small USDC balance for Arc gas.
- Links are bearer information: the reference is public to recipients of the link and is emitted on-chain when paid.
- Inline QR generation uses byte mode, error correction M and versions 1–10. Extremely long or heavily URL-escaped
  links can exceed that QR capacity; the complete link remains available to copy.

## License

MIT
