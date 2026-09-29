# Haskell Ledger

A full-stack double-entry ledger: a Haskell API that moves money between accounts and enforces bookkeeping rules, with property-based tests and a React + TypeScript + Redux Toolkit front end.

> **Status: work in progress.** The API runs today. The test suite, front end and CI are still to come; see [Progress](#progress).
>
> Built step by step while learning Haskell, so every source file carries beginner-level comments explaining the Haskell it uses.

## What it does

- **Double-entry bookkeeping.** Every transfer writes two entries, a debit and a credit, that sum to zero. An account's balance is the sum of its entries.
- **No overdrafts.** Customer accounts can never go below zero. An `external` account represents money outside the ledger and is allowed to go negative.
- **Atomic transfers.** Each transfer runs in one STM transaction, so concurrent requests can't overdraw an account.
- **Idempotency.** A client can send an `Idempotency-Key` header. Retrying with the same key returns the original result instead of moving money twice. Reusing a key with a different request is rejected.
- **Money is integer cents,** never floating point, on the server, on the wire and in the browser.

## Design

| Module | Responsibility |
| --- | --- |
| `Ledger.Money` | `Cents` and `Amount`. An `Amount` can only be built through `mkAmount`, which rejects zero and negatives. |
| `Ledger.Types` | Domain types: accounts, transfers, entries, and errors as data. |
| `Ledger.Core` | Pure ledger rules, with no IO. |
| `Ledger.Store` | Storage interface as a record of functions, with an in-memory STM implementation. |
| `Ledger.App` | HTTP layer (Scotty). The only place domain errors become status codes. |

The rules live in pure functions, so the test suite checks them with QuickCheck over hundreds of random transfer sequences:

- the sum of all balances is always zero
- no customer account ever goes negative
- every balance equals the sum of that account's entries

## Tech stack

| Layer | Technology |
| --- | --- |
| Backend | Haskell (GHC 9.4.8), Scotty, STM, aeson |
| Tests | hspec, QuickCheck |
| Frontend | React, TypeScript, Redux Toolkit (RTK Query), Vite |
| Tooling | GHCup, cabal, Node 22, GitHub Actions |

## Running locally

Requires GHC 9.4.8 and cabal (install both with [GHCup](https://www.haskell.org/ghcup/)), and Node 22.

```sh
# Build the backend (the first build compiles dependencies and takes a while)
cd backend
cabal build all

# Run the API on http://localhost:8080 (set PORT to use another port)
cabal run ledger-api
```

The server keeps everything in memory, so each restart begins from the same seed data:

| Account | Kind | Starting balance |
| --- | --- | --- |
| `external` | External | -$25,000.00 |
| `acme-ops` | Customer | $25,000.00 |
| `acme-payroll` | Customer | $0.00 |

The external balance is negative because the seed deposit came from outside the ledger. All balances always sum to zero.

Coming in later steps:

```sh
# Tests (Step 7)
cabal test --test-show-details=direct

# Front end on http://localhost:5173, in a second terminal (Steps 8-9)
cd web
npm install
npm run dev
```

In development, Vite will proxy `/api` requests to the Haskell server, so no CORS setup is needed.

## Try it

With the API running:

```sh
# List accounts and balances
curl localhost:8080/api/accounts

# Move $1,500 with an idempotency key. Run it twice: the same transfer comes
# back both times and the money moves only once.
curl -X POST localhost:8080/api/transfers \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: payroll-1' \
  -d '{"from": "acme-ops", "to": "acme-payroll", "amountCents": 150000, "memo": "September payroll"}'

# Try to overdraw: 422 insufficient_funds
curl -X POST localhost:8080/api/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from": "acme-payroll", "to": "acme-ops", "amountCents": 99999999}'

# The double-entry view of one account
curl localhost:8080/api/accounts/acme-payroll/entries
```

## API

| Method | Path | Description | Success |
| --- | --- | --- | --- |
| `GET` | `/api/health` | Health check | 200 |
| `GET` | `/api/accounts` | List accounts with balances | 200 |
| `POST` | `/api/accounts` | Open a customer account: `{ "id", "name" }` | 201 |
| `GET` | `/api/accounts/:id` | One account with its balance | 200 |
| `GET` | `/api/accounts/:id/entries` | An account's ledger entries, newest first | 200 |
| `POST` | `/api/deposits` | Deposit from outside: `{ "to", "amountCents" }` | 201 |
| `POST` | `/api/transfers` | Transfer: `{ "from", "to", "amountCents", "memo"? }`, optional `Idempotency-Key` header | 201 |

Amounts are integer cents: `150000` is $1,500.00.

Errors come back as `{ "error": "<code>", "message": "<text>" }`:

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad_request` | The body isn't valid JSON or is missing a field |
| 400 | `invalid_amount` | `amountCents` is zero or negative |
| 404 | `unknown_account` | An account in the request doesn't exist |
| 409 | `account_exists` | Opening an account with an id that's taken |
| 409 | `idempotency_key_reused` | The same `Idempotency-Key` was sent with a different request |
| 422 | `same_account` | `from` and `to` are the same account |
| 422 | `insufficient_funds` | The transfer would take a customer account below zero |

## Progress

- [x] Domain types (`Ledger.Money`, `Ledger.Types`)
- [x] Pure core and STM store
- [x] HTTP layer and executable
- [ ] Tests
- [ ] Front end
- [ ] CI

## Repository layout

```
haskell-ledger/
  cabal.project              # points cabal and the editor at backend/
  backend/
    double-entry-ledger.cabal
    app/Main.hs              # entry point: seeds data, starts the server
    src/Ledger/*.hs          # the library (see Design)
    test/Spec.hs             # Step 7
  web/                       # Vite + React + TypeScript (Steps 8-9)
  .github/workflows/ci.yml   # CI (later step)
```

Because `cabal.project` sits at the root, `cabal build all` works from either the root or `backend/`.
