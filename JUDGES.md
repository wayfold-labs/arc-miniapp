# PayLink — judge walkthrough

## Wallet-free path first (about 20 seconds)

1. Open [this paid invoice link](https://wayfold-labs.github.io/arc-miniapp/?ref=INV-2026-0001&id=0x96caac3ddf966c9306266c6b7906f5fd700cc1931129e88477027b0095f1c797&to=0x01f0319D07167C7907B248edd9AB9bc93f85aB50&amt=1.25&cur=USDC). It is a real Arc mainnet request (1.25 USDC, `INV-2026-0001`); no
   wallet or account is needed.
2. The browser calls PayLink's `paidBlock`, reads only that exact block, validates the matching `Paid` event and shows
   payer, recipient, amount, timestamp, block and transaction links.
3. Download the JSON or CSV receipt. Downloads are enabled only because the event matched every request field.

This demonstrates the core public-verification experience directly from chain state, without a backend or indexer.

## Paying path (about 60 seconds)

1. Open https://wayfold-labs.github.io/arc-miniapp/ and create a EURC or USDC request. Confirm the recipient: links
   are not signed, so an edited link can point somewhere else.
2. Open the generated link and connect an injected wallet on Arc mainnet. The app checks that PayLink has code and
   that its `USDC()`/`EURC()` match the app's token addresses, then verifies the Circle token's on-chain EIP-712 domain
   before requesting a signature.
3. Sign the one-hour `ReceiveWithAuthorization`. EOAs use the `v/r/s` PayLink overload; smart-contract wallets that
   return another signature shape use the bytes overload and Circle's ERC-1271 validation.
4. Confirm one transaction. Arc Memo normally records an EOA payer's reference and calls PayLink. Smart-contract
   wallets use the direct PayLink call because Memo requires `msg.sender == tx.origin`. For EOAs, a direct fallback
   appears only if Memo fails and the exact direct call successfully simulates.
5. Watch the page confirm the receipt and retry its state/event lookup. Reload the link to verify the same payment and
   download a receipt. A second payment of the exact request is rejected.

## What is Arc-specific

- EURC and USDC invoices share one chain, and USDC pays gas.
- Circle FiatToken v2.2 EIP-3009 makes authorization plus payment a single transaction and supports ERC-1271 wallets.
- Arc Memo can anchor an EOA invoice reference at the protocol layer. PayLink's `Paid` event is authoritative; the Memo
  record is only a convenience and can be missing if another account submits the authorization directly.
- Fast confirmation supports immediate browser verification.
- Exact-block reads avoid the public RPC's bounded log-history scans.

## Reproduce locally

```bash
forge build
forge test

CHROME=/path/to/chrome-or-chromium \
./e2e.sh
```

Add `?debug=1` to the app URL for a visible pass/fail list covering ABI selectors, the shared Solidity/JavaScript
request-key vector, EIP-712, exact decimal parsing, link ordering, Keccak and QR vectors.

## Roadmap

- CCTP settlement: let Arc users pay an invoice from supported remote chains while the merchant receives Arc USDC.
- Reusable merchant profiles: publish signed recipient/currency templates so payers can authenticate businesses before
  opening an invoice link.
- Accounting integrations: export verified Arc receipts directly into bookkeeping tools while retaining the static,
  non-custodial payment path.
- Recurring billing: add payer-controlled, capped authorization schedules for subscriptions and repeat invoices.
- Multi-signature receipts: attach merchant acknowledgements to on-chain payment evidence for stronger dispute and
  reconciliation workflows.
