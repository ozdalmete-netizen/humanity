# HUMANITY/1 live security baseline

Snapshot date: 2026-08-26

This file documents controls read directly from the production Supabase project. It is not a substitute for executable migrations/tests, but gives reviewers the live enforcement baseline.

## Permanent mark invariant
A mark may be inserted only after verified successful server-side payment evidence. `marks` is protected by:
- BEFORE INSERT trigger: `marks_verified_payment_guard`
- BEFORE UPDATE/DELETE trigger: `marks_immutable_guard`
- UNIQUE `(canvas,x,y)`

Both mark triggers were active at snapshot time.

## Direct database access
At snapshot time `anon` and `authenticated` could not:
- INSERT marks
- UPDATE payments
- UPDATE checkout_batches
- execute the critical SECURITY DEFINER RPCs listed below
- CREATE objects in schema `public`

Critical SECURITY DEFINER routines are restricted to privileged execution and have `search_path=pg_catalog, public, extensions`:
- `reserve_batch_atomic`
- `begin_dodo_checkout_atomic`
- `process_dodo_payment_atomic`
- `begin_crypto_payment_atomic`
- `process_nowpayments_payment_atomic`
- `consume_reservation_rate_limit`

## Reservation enforcement
The live reservation RPC independently enforces:
- canvas validity and unlocked state
- 1–1000 items
- coordinate bounds
- color IDs 1–32
- duplicate-coordinate rejection
- deterministic per-cell advisory locks
- sealed/active-reservation conflict checks
- server-side price = `item_count * 499` USD cents
- reservation token hash storage

## Dodo live path
The live checkout path is intentionally locked pre-reset (`LIVE_ARMED=false`). The live webhook verifies signature, re-fetches the payment from Dodo live API, verifies live environment, product/cart/quantity/session/order metadata, rejects discounts, verifies the configured product is exactly one-time $4.99 USD with tax-inclusive pricing off, and blocks nominal underpayment before calling the atomic payment processor.

## NOWPayments path
The IPN handler verifies HMAC-SHA512, re-fetches the payment from NOWPayments, binds payment/order IDs, and calls the atomic processor. The database keeps the original quoted crypto `pay_amount`; webhook processing cannot overwrite the original quote. A non-destructive regression check returned `UNDERPAYMENT_BLOCKED` for a deliberately lower `actually_paid` value.

## Webhook idempotency
`webhook_events` has a DB-level unique index on `(provider, provider_event_id)`.

## Current pre-reset runtime state
This repository baseline does not reset production data. At snapshot time:
- Human marks: 26, sealed_count: 26
- AI marks: 1109, sealed_count: 1109
- Total marks: 1135
- Counter drift: 0

Final reset remains a separate explicitly authorized destructive operation.
