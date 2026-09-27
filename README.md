# PayLink on Arc

Ask for USDC with a link. The payer pays in one transaction, and gas is paid in USDC too.

On [Arc](https://docs.arc.io), USDC is the native gas token (18 decimals). PayLink uses that: the payer sends the
requested amount as the transaction value, and a tiny stateless contract forwards it to the recipient and records a
`Paid` event keyed by the request id. There is no token approval step, no second currency for gas, and no funds are
ever held by the contract.

## How it works

1. **Create a request.** The web app takes a recipient address, an amount and an optional memo (for example an invoice
   number), draws a random 32-byte id and turns everything into a link. Nothing is stored anywhere: the link is the
   request.
2. **Pay.** The payer opens the link, connects a browser wallet, and sends one transaction to
   `PayLink.pay(id, recipient, memo)` with the amount as value.
3. **Check.** Anyone with the link can see whether it was paid. The contract remembers the block of the first payment
   that matches the request exactly (id, recipient, amount and memo), so the app needs one `eth_call` to
   `paidBlock(...)` and then reads that single block's `Paid` log for the payer and the transaction. No log scanning
   across block ranges, which public RPCs limit.

## Contract

`src/PayLink.sol`, about 40 lines. It rejects a zero recipient, a zero amount and memos longer than 140 bytes, forwards
the value with a plain call and reverts the whole payment if the recipient cannot receive it.

```
function pay(bytes32 id, address payable recipient, string calldata memo) external payable;
function paidBlock(bytes32 id, address recipient, uint256 amount, string calldata memo) external view returns (uint256);
event Paid(bytes32 indexed id, address indexed payer, address indexed recipient, uint256 amount, string memo);
```

## Develop

Requires [Foundry](https://getfoundry.sh).

```
forge test          # contract unit and fuzz tests
./e2e.sh            # deploys to a local anvil chain, pays a request and checks the page in headless Chrome
```

The web app is a single static file, `docs/index.html`, with no dependencies. It is served with GitHub Pages.

## Networks

| | Chain id | RPC | Explorer |
|---|---|---|---|
| Arc mainnet | 5042 | https://rpc.mainnet.arc.io | https://explorer.arc.io |
| Arc testnet | 5042002 | https://rpc.testnet.arc.io | https://explorer.testnet.arc.io |

Payments on a blockchain are final: check the recipient address before paying. Not affiliated with Circle or Arc.

## License

MIT
