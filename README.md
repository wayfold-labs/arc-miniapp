# PayLink on Arc

PayLink turns a EURC or USDC invoice into a shareable link. A freelancer or small business chooses a currency,
recipient, amount and reference; the payer signs a Circle EIP-3009 authorization and completes the request in one
transaction. The static app is available at https://wayfold-labs.github.io/arc-miniapp/ and the source is at
https://github.com/wayfold-labs/arc-miniapp .

There is no custody, fee, approval transaction, backend or swap. PayLink pulls the authorized amount, forwards it to
the recipient atomically, records the payment block and emits a receipt event. Each exact request can be paid once.

## Why Arc

- Arc supports EURC and USDC; USDC is also the native gas token.
- Circle FiatToken v2.2 exposes EIP-3009 `receiveWithAuthorization` overloads for EOAs and ERC-1271 smart-contract
  wallets, removing a separate approval transaction.
- Arc Memo wraps EOA payments by default and records the invoice reference at the protocol layer.
- Fast confirmation and exact-block event reads let a static page verify payments without an indexer.

## How it works

1. The browser creates a random request ID and a link containing the network, reference, recipient, exact six-decimal
   amount and currency. Nothing is uploaded.
2. The payer checks the recipient. Payment links are not signed: anyone who edits a link before forwarding it can
   replace the recipient, so confirm the address with whoever sent the link.
3. The app checks that PayLink has code and that its `USDC()`/`EURC()` match the app's token addresses, then checks the
   token's EIP-712 domain.
4. The wallet signs `ReceiveWithAuthorization` for PayLink. The nonce is
   `keccak256(abi.encode(id, token, recipient, amount, ref))`.
5. Arc Memo normally submits an EOA's call. Smart-contract wallets call PayLink directly because Memo requires
   `msg.sender == tx.origin`. If Memo itself fails and a direct call simulation succeeds, the app offers an EOA the
   same authorized PayLink call directly.
6. PayLink marks the exact request paid before its external calls, consumes the authorization and forwards the tokens.
   Any failure reverts all state. A successful request cannot be paid again.
7. The page reads `paidBlock`, then validates the matching `Paid` event in that exact block before enabling receipt
   downloads.

Anyone may submit a payer's signed authorization. It can only pay the exact request, including its recipient and
amount. A bot copying a pending transaction may make the payer's own transaction fail as already paid, but can never
redirect the funds or change the request.

## Contract interface

```solidity
constructor(address usdc, address eurc);

function payWithAuthorization(
    bytes32 id, address token, address payer, address recipient, uint256 amount, string ref,
    uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s
) external;

function payWithAuthorization(
    bytes32 id, address token, address payer, address recipient, uint256 amount, string ref,
    uint256 validAfter, uint256 validBefore, bytes signature
) external;

function paidBlock(bytes32 id, address token, address recipient, uint256 amount, string ref)
    external view returns (uint256);

event Paid(
    bytes32 indexed id, address indexed payer, address indexed recipient,
    address token, uint256 amount, string ref
);
```

The `bytes` overload allows Circle FiatToken v2.2 to validate ERC-1271 signatures for smart-contract payers. References
are limited to 140 UTF-8 bytes and amounts must be non-zero. The recipient cannot be PayLink, USDC or EURC.

## Security properties and limits

- No owner, admin, upgrade path, fee logic, custody or swap logic.
- Only the immutable USDC and EURC addresses supplied at deployment are accepted.
- A request key binds the ID, token, recipient, amount and reference, and can transition from unpaid to paid only once.
- FiatToken requires the authorization caller to be its designated payee (PayLink).
- Authorization, forwarding, paid state and event emission are atomic.
- Smart-contract wallets pay through the direct PayLink call because Arc Memo requires `msg.sender == tx.origin`.
- PayLink's `Paid` event is the authoritative payment record. The Memo record is a convenience and can be absent when
  another account submits the payer's authorization directly.
- Direct token transfers to PayLink, outside `payWithAuthorization`, are unrecoverable. Do not send tokens to the
  contract address.
- A EURC payer needs a small USDC balance for gas.
- References and payment details are public to anyone with the link and are emitted on-chain when paid.
- Inline QR generation supports byte mode, error correction M and versions 1–10; a very long escaped link may need to
  be copied instead.

## Develop and test

Foundry is the only contract dependency. The app is one self-contained `docs/index.html` with no external scripts.

```bash
forge build
forge test

CHROME=/path/to/chrome-or-chromium \
./e2e.sh
```

The e2e script starts Anvil with Arc testnet's chain ID, deploys a local FiatToken-style token and PayLink, signs and
submits a real authorization through the bytes overload, verifies duplicate rejection, and asks headless Chrome to
check paid, unpaid and visible self-test states.

Deploy once to Arc mainnet with:

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url "$ARC_RPC" --private-key "$DEPLOYER_KEY" --broadcast
```

## Mainnet deployment and evidence

| Item | Value |
|---|---|
| App | https://wayfold-labs.github.io/arc-miniapp/ |
| Repository | https://github.com/wayfold-labs/arc-miniapp |
| Arc mainnet chain ID | `5042` |
| PayLink | [`<CONTRACT_ADDRESS>`](https://explorer.arc.io/address/<CONTRACT_ADDRESS>) |
| Sourcify | [`<SOURCIFY_URL>`](https://repo.sourcify.dev/5042/<CONTRACT_ADDRESS>) |
| Deployment transaction | [`<DEPLOY_TX>`](https://explorer.arc.io/tx/<DEPLOY_TX>) |
| Paid transaction 1 | [`<PAID_TX_1>`](https://explorer.arc.io/tx/<PAID_TX_1>) |
| Paid transaction 2 | [`<PAID_TX_2>`](https://explorer.arc.io/tx/<PAID_TX_2>) |
| Browser-verifiable paid link | [`<PAID_LINK>`](<PAID_LINK>) |
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` |
| Arc Memo | `0x5294E9927c3306DcBaDb03fe70b92e01cCede505` |

Source verification will be published through Sourcify. The Arc explorer verification API is currently behind a
Cloudflare challenge; see `circlefin/arc-node` issue 425.

## License

MIT
