# Haskell Ledger

A full-stack double-entry ledger: a Haskell API that moves money between accounts and enforces bookkeeping rules, backed by PostgreSQL, with property-based tests and a React + TypeScript + Redux Toolkit front end.

> **Status: work in progress.** The API, its test suite and the Postgres store work today. Users and authentication, the front end and CI are still to come; see [Progress](#progress).
>
> Built step by step while learning Haskell, so every source file carries beginner-level comments explaining the Haskell it uses.

## What it does

- **Double-entry bookkeeping.** Every transfer writes two entries, a debit and a credit, that sum to zero. An account's balance is the sum of its entries.
- **No overdrafts.** Customer accounts can never go below zero. An `external` account represents money outside the ledger and is allowed to go negative.
- **Atomic, concurrency-safe transfers.** In Postgres, each transfer is one transaction that locks both account rows before reading balances. In memory, it's one STM transaction. Either way, concurrent requests can't overdraw an account.
- **Idempotency.** A client can send an `Idempotency-Key` header. Retrying with the same key returns the original result, success or error, instead of moving money twice. Reusing a key with a different request is rejected.
- **Money is integer cents,** never floating point, in the database, on the server, on the wire and in the browser.
- **The database checks the rules too.** Constraints reject a negative customer balance, a non-positive amount, and a transfer whose entries don't sum to zero, even if the application code were wrong.

## Design

| Module | Responsibility |
| --- | --- |
| `Ledger.Money` | `Cents` and `Amount`. An `Amount` can only be built through `mkAmount`, which rejects zero and negatives. |
| `Ledger.Types` | Domain types: accounts, transfers, entries, and errors as data. |
| `Ledger.Core` | Pure ledger rules, with no IO. `checkTransfer` holds the transfer rules, and both stores use it. |
| `Ledger.Store` | Storage interface as a record of functions, with an in-memory STM implementation. |
| `Ledger.Store.Postgres` | The same interface backed by PostgreSQL. |
| `Ledger.Db` | Connection pool, and a migration runner for the SQL files in `backend/db/migrations`. |
| `Ledger.App` | HTTP layer (Scotty). The only place domain errors become status codes. |

The API uses Postgres when `DATABASE_URL` is set, and the in-memory store otherwise. Nothing outside `app/Main.hs` knows which one it's using.

## Tests

The rules live in pure functions, so the test suite checks them with QuickCheck over hundreds of random sequences of deposits and transfers (100 per property, checked after every step):

- the sum of all balances is always zero
- no customer account ever goes negative
- every balance equals the sum of that account's entries

Example tests (hspec) cover amount validation and each rejection case. The store tests run against **both** stores, the in-memory one and Postgres:

- an idempotent request sent twice moves money once
- a reused key with a different request is rejected
- a failed request is remembered: a retry gets the same error even after the balance changes
- unknown and duplicate accounts are reported
- 200 concurrent 10-cent transfers from a 1,000-cent account: exactly 100 succeed and the balance ends at zero
- 200 concurrent transfers in opposite directions between two accounts all succeed, with no deadlocks

The Postgres tests run when `TEST_DATABASE_URL` is set, and are marked pending otherwise:

```sh
cd backend
cabal test --test-show-details=direct
# 16 examples, 0 failures, 1 pending

TEST_DATABASE_URL=postgresql://ledger:ledger@localhost:5434/ledger_test \
  cabal test --test-show-details=direct
# 21 examples, 0 failures
```

The test suite empties every table in `ledger_test` between tests, so never point `TEST_DATABASE_URL` at a database you care about.

## Tech stack

| Layer | Technology |
| --- | --- |
| Backend | Haskell (GHC 9.4.8), Scotty, STM, aeson |
| Database | PostgreSQL 16, postgresql-simple, resource-pool |
| Tests | hspec, QuickCheck |
| Frontend | React, TypeScript, Redux Toolkit (RTK Query), Vite |
| Tooling | GHCup, cabal, Docker Compose, Node 22, GitHub Actions |

## Running locally

Requires:

- GHC 9.4.8 and cabal (install both with [GHCup](https://www.haskell.org/ghcup/))
- Docker, for Postgres
- `libpq`, Postgres's C client library, which the Haskell driver links against. On macOS: `brew install libpq` (or any Homebrew `postgresql@XX`).
- Node 22, for the front end (later step)

### 1. Start Postgres

```sh
docker compose up -d
```

This starts two services:

| Service | Address | What it is |
| --- | --- | --- |
| `db` | `localhost:5434` | Postgres 16 with two databases: `ledger` (the app) and `ledger_test` (the test suite). User and password are both `ledger`. |
| `adminer` | <http://localhost:8081> | A web UI for browsing the database |

The data lives in a Docker volume, so it survives `docker compose down`. To start from scratch, run `docker compose down -v`.

### 2. Run the API

```sh
cd backend
cabal build all   # the first build compiles dependencies and takes a while

DATABASE_URL=postgresql://ledger:ledger@localhost:5434/ledger cabal run ledger-api
# Applied migration 0001_create_ledger.sql
# Using the Postgres store
# Ledger API listening on http://localhost:8080
```

On startup the API applies any new migrations, then seeds demo data. Seeding is safe to repeat: each seed transfer carries an idempotency key, so restarting never moves the money twice.

| Account | Kind | Balance after seeding |
| --- | --- | --- |
| `external` | External | -$25,000.00 |
| `acme-ops` | Customer | $21,000.00 |
| `acme-payroll` | Customer | $4,000.00 |

That's a $25,000 deposit into `acme-ops`, then $4,000 of August payroll to `acme-payroll`. The external balance is negative because the deposit came from outside the ledger, and all balances always sum to zero.

Without `DATABASE_URL`, `cabal run ledger-api` uses the in-memory store instead. That needs no Docker, but the data is lost on restart. Set `PORT` to use a port other than 8080.

### 3. Look at the data

**Adminer:** open <http://localhost:8081> and log in with:

| Field | Value |
| --- | --- |
| System | PostgreSQL |
| Server | `db` |
| Username | `ledger` |
| Password | `ledger` |
| Database | `ledger` |

**psql:**

```sh
docker compose exec db psql -U ledger
```

```sql
SELECT id, kind, balance FROM accounts ORDER BY id;
SELECT sum(balance) FROM accounts;                    -- always 0
SELECT * FROM entries ORDER BY id;                    -- two rows per transfer
SELECT key, transfer_id, error FROM idempotency_keys; -- remembered outcomes
```

### Coming in later steps

```sh
# Front end on http://localhost:5173, in a second terminal
cd web
npm install
npm run dev
```

In development, Vite will proxy `/api` requests to the Haskell server, so no CORS setup is needed.

## Try it

With the API running, use `curl` as below, or open [`backend/api.http`](backend/api.http) in VS Code with the [REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) extension and click **Send Request** above each block.

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
- [x] Tests
- [x] PostgreSQL store, migrations, seed data and Docker Compose
- [ ] Users, sessions and account ownership
- [ ] Front end
- [ ] CI
- [ ] Run the whole app with `docker compose up`

## Repository layout

```text
haskell-ledger/
  cabal.project              # points cabal and the editor at backend/
  docker-compose.yml         # Postgres and Adminer for local development
  docker/postgres-init/      # creates the ledger_test database on first start
  backend/
    double-entry-ledger.cabal
    app/Main.hs              # entry point: picks a store, seeds data, starts the server
    src/Ledger/*.hs          # the library (see Design)
    db/migrations/*.sql      # schema changes, applied in order at startup
    test/Spec.hs             # hspec examples and QuickCheck properties
    api.http                 # sample requests for the REST Client extension
  web/                       # Vite + React + TypeScript (later step)
  .github/workflows/ci.yml   # CI (later step)
```

Because `cabal.project` sits at the root, `cabal build all` works from either the root or `backend/`.
