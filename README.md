# Haskell Ledger

A full-stack double-entry ledger: a Haskell API that moves money between accounts and enforces bookkeeping rules, with property-based tests and a React + TypeScript + Redux Toolkit front end.

> **Status: work in progress.** Built step by step while learning Haskell. See [Progress](#progress).

## What it does

- **Double-entry bookkeeping.** Every transfer writes two entries, a debit and a credit, that sum to zero. An account's balance is the sum of its entries.
- **No overdrafts.** Customer accounts can never go below zero. An `external` account represents money outside the ledger and is allowed to go negative.
- **Atomic transfers.** Each transfer runs in one STM transaction, so concurrent requests can't overdraw an account.
- **Idempotency.** A client can send an `Idempotency-Key` header. Retrying with the same key returns the original result instead of moving money twice. Reusing a key with a different request is rejected.
- **Money is integer cents,** never floating point, on the server, on the wire and in the browser.

## Design

| Module | Responsibility |
|---|---|
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
|---|---|
| Backend | Haskell (GHC 9.4.8), Scotty, STM, aeson |
| Tests | hspec, QuickCheck |
| Frontend | React, TypeScript, Redux Toolkit (RTK Query), Vite |
| Tooling | GHCup, cabal, Node 22, GitHub Actions |

## Running locally

Requires GHC 9.4.8 and cabal (install both with [GHCup](https://www.haskell.org/ghcup/)), and Node 22.

```sh
# Build and test the backend (the first build compiles dependencies and takes a while)
cd backend
cabal build all
cabal test --test-show-details=direct

# Run the API on http://localhost:8080
cabal run ledger-api
```

```sh
# In a second terminal: run the front end on http://localhost:5173
cd web
npm install
npm run dev
```

In development, Vite proxies `/api` requests to the Haskell server, so no CORS setup is needed.

## API

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/health` | Health check |
| `GET` | `/api/accounts` | List accounts with balances |
| `POST` | `/api/accounts` | Open an account: `{ "id", "name" }` |
| `GET` | `/api/accounts/:id` | One account with its balance |
| `GET` | `/api/accounts/:id/entries` | An account's ledger entries, newest first |
| `POST` | `/api/deposits` | Deposit from outside: `{ "to", "amountCents" }` |
| `POST` | `/api/transfers` | Transfer: `{ "from", "to", "amountCents", "memo"? }`, optional `Idempotency-Key` header |

Errors come back as `{ "error": "<code>", "message": "<text>" }`, for example `422 insufficient_funds` or `409 idempotency_key_reused`.

## Progress

- [x] Domain types (`Ledger.Money`, `Ledger.Types`)
- [x] Pure core and STM store
- [ ] HTTP layer and executable
- [ ] Tests
- [ ] Front end
- [ ] CI

## Repository layout

```
haskell-ledger/
  cabal.project          # points cabal and the editor at backend/
  backend/
    double-entry-ledger.cabal
    app/Main.hs
    src/Ledger/*.hs
    test/Spec.hs
  web/                   # Vite + React + TypeScript
  .github/workflows/ci.yml
```
