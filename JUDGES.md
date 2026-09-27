# PayLink v2 — 60-second walkthrough

## Create → pay → verify

**0–15 seconds — Create.** Open the static app, keep Arc mainnet selected, choose **EURC (€)** or **USDC ($)**, and
enter a recipient, amount and invoice reference. Click **Create link**. The random request ID and every request field
are in the link; no backend or account exists. Share the link or scan its inline QR code.

**15–40 seconds — Pay.** Open the link and connect an injected wallet. PayLink switches to Arc, verifies the selected
Circle token's on-chain EIP-712 domain, and asks for a one-hour `ReceiveWithAuthorization` signature. Confirm one Arc
transaction. By default it goes through Arc Memo, so the same invoice reference is recorded there while PayLink pulls
the exact authorized amount and immediately forwards it to the business.

**40–60 seconds — Verify.** As soon as the receipt arrives, the page displays **Paid** with payer, timestamp, block and
transaction links. Reload it in another browser: the app makes one `paidBlock` call, then reads `Paid` only from that
single block. Download the self-contained CSV or JSON receipt.

## What is Arc-specific

- Two Circle currencies on one chain: euro requests use EURC and dollar requests use USDC.
- USDC is Arc's native gas token, including for EURC payments.
- Circle FiatToken v2 EIP-3009 authorizations make approval plus payment a single payer transaction.
- Arc Memo wraps the payment and anchors the invoice reference at the protocol layer.
- Fast confirmation supports an instant paid experience without a hosted indexer.
- Exact-block status reads avoid Arc public RPC's 9,999-block `eth_getLogs` limit.

## Reproduce

```bash
# Foundry (https://getfoundry.sh) on PATH
forge build
forge test

CHROME=/path/to/chrome-or-chromium \
./e2e.sh
```

Add `?debug=1` to the app URL to run its browser self-test vectors for ABI encoding, exact-request hashing, EIP-712,
six-decimal parsing, link round trips, Keccak and QR encoding.

## Roadmap

- Cross-chain invoice payment and settlement through CCTP.
- Recurring invoice authorizations with clear payer controls.
- Richer accounting exports and integrations while keeping the payment path non-custodial.
