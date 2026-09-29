# Haskell Ledger

A full-stack double-entry ledger: a Haskell API that moves money between accounts and enforces bookkeeping rules, backed by PostgreSQL, with property-based tests and a React + TypeScript + Redux Toolkit front end.

> **Status: work in progress.** The API, its test suite, the Postgres store and user logins work today. The front end and CI are still to come; see [Progress](#progress).
>
> Built step by step while learning Haskell, so every source file carries beginner-level comments explaining the Haskell it uses.

## What it does

- **Double-entry bookkeeping.** Every transfer writes two entries, a debit and a credit, that sum to zero. An account's balance is the sum of its entries.
- **No overdrafts.** Customer accounts can never go below zero. An `external` account represents money outside the ledger and is allowed to go negative.
- **Atomic, concurrency-safe transfers.** In Postgres, each transfer is one transaction that locks both account rows before reading balances. In memory, it's one STM transaction. Either way, concurrent requests can't overdraw an account.
- **Idempotency.** A client can send an `Idempotency-Key` header. Retrying with the same key returns the original result, success or error, instead of moving money twice. Reusing a key with a different request is rejected.
- **Money is integer cents,** never floating point, in the database, on the server, on the wire and in the browser.
- **Users and permissions.** Users log in with a password and get a session cookie. Customers see and send from only their own accounts; admins see everything and are the only ones who can bring money in (deposits). See [Security](#security).
- **The database checks the rules too.** Constraints reject a negative customer balance, a non-positive amount, and a transfer whose entries don't sum to zero, even if the application code were wrong.

## Design

| Module | Responsibility |
| --- | --- |
| `Ledger.Money` | `Cents` and `Amount`. An `Amount` can only be built through `mkAmount`, which rejects zero and negatives. |
| `Ledger.Types` | Domain types: accounts, transfers, entries, and errors as data. |
| `Ledger.Core` | Pure ledger rules, with no IO. `checkTransfer` holds the transfer rules, and both stores use it. |
| `Ledger.Store` | Storage interfaces as records of functions (`LedgerStore` for money, `UserStore` for users and sessions), with in-memory STM implementations. |
| `Ledger.Store.Postgres` | The same interfaces backed by PostgreSQL. |
| `Ledger.Db` | Connection pool, and a migration runner for the SQL files in `backend/db/migrations`. |
| `Ledger.Validate` | Rules for the text clients send: account ids and names, memos, idempotency keys. |
| `Ledger.Auth` | Who may do what: pure permission rules, e.g. `canSendFrom`. |
| `Ledger.Session` | Argon2 password hashing, and random session tokens stored only as SHA-256 hashes. |
| `Ledger.Seed` | The `external` account every ledger needs, and the demo users and data. |
| `Ledger.App` | HTTP layer (Scotty): logins, permission checks, and the only place domain errors become status codes. |

The API uses Postgres when `DATABASE_URL` is set, and the in-memory store otherwise. Only the two programs' `Main` modules choose a store; nothing else knows which one it's using.

## Tests

The rules live in pure functions, so the test suite checks them with QuickCheck over hundreds of random sequences of deposits and transfers (100 per property, checked after every step):

- the sum of all balances is always zero
- no customer account ever goes negative
- every balance equals the sum of that account's entries

Example tests (hspec) cover amount validation, each transfer rule and each rejection case. The store tests are written once, as contracts every `LedgerStore` and `UserStore` must meet, and run against **both** kinds of store, in-memory and Postgres. The ledger store contract checks that:

- an idempotent request sent twice moves money once
- a reused key with a different request is rejected
- a failed request is remembered: a retry gets the same error even after the balance changes
- unknown and duplicate accounts are reported
- accounts are listed in id order with their balances
- 200 concurrent 10-cent transfers from a 1,000-cent account: exactly 100 succeed and the balance ends at zero
- 200 concurrent transfers in opposite directions between two accounts all succeed, with no deadlocks

The HTTP tests log in as each demo user and check every permission rule: customers see only their own accounts, someone else's account answers 404 as if it didn't exist, nobody can send from an account they don't own (not even an admin), only admins can deposit, logging out ends the session, and one user's idempotency keys can't replay another's transfers.

The Postgres tests run when `TEST_DATABASE_URL` is set, and are marked pending otherwise:

```sh
cd backend
cabal test --test-show-details=direct
# 80 examples, 0 failures, 1 pending

TEST_DATABASE_URL=postgresql://ledger:ledger@localhost:5434/ledger_test \
  cabal test --test-show-details=direct
# 89 examples, 0 failures
```

The tests are split by area under `backend/test`:

| File | What it tests |
| --- | --- |
| `Ledger/AppSpec.hs` | The HTTP API: logging in and out, permissions, status and error codes, input checks, the body size limit, and a JSON 500 that doesn't leak details |
| `Ledger/AuthSpec.hs` | The permission rules in `Ledger.Auth` |
| `Ledger/SessionSpec.hs` | Password hashing and session tokens |
| `Ledger/UserStoreSpec.hs` | The user store contract against the in-memory store |
| `Ledger/MoneySpec.hs` | `mkAmount` (including the maximum amount) and `formatCents` |
| `Ledger/ValidateSpec.hs` | The rules for account ids and names, memos and idempotency keys |
| `Ledger/MigrationsSpec.hs` | Every SQL file in `db/migrations` is listed in `Ledger.Db` |
| `Ledger/SeedSpec.hs` | The demo data applies cleanly, keeps every rule, gives each account the right owner, and seeding twice changes nothing |
| `Ledger/CoreSpec.hs` | `checkTransfer`, `applyTransfer` and `openAccount` examples |
| `Ledger/InvariantsSpec.hs` | The QuickCheck properties |
| `Ledger/StoreSpec.hs` | The store contract against the in-memory store |
| `Ledger/Store/PostgresSpec.hs` | Both store contracts against Postgres |
| `Support/Fixtures.hs` | Shared account ids and shorthands |
| `Support/Generators.hs` | Random transfer sequences for QuickCheck |
| `Support/StoreContract.hs` | The tests every `LedgerStore` must pass |
| `Support/UserStoreContract.hs` | The tests every `UserStore` must pass |

[hspec-discover](https://hspec.github.io/hspec-discover.html) finds every `*Spec.hs` module automatically, so a new spec file only needs adding to `other-modules` in the cabal file.

The Postgres tests empty every table between tests. As a safety net, they refuse to run unless the database's name ends in `_test`.

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
- Optional, for editor support in `backend/test/Spec.hs`: `cabal install hspec-discover`. The Haskell language server needs the `hspec-discover` program on your `PATH`. `cabal build` and `cabal test` don't, because cabal builds it for them.

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

### 2. Add demo data

```sh
cd backend
cabal build all   # the first build compiles dependencies and takes a while

export DATABASE_URL=postgresql://ledger:ledger@localhost:5434/ledger
cabal run ledger-seed
```

`ledger-seed` applies any new migrations, adds the demo users and data, and prints every balance. Running it again changes nothing: existing users keep their passwords, and each seed transfer carries an idempotency key, so a second run replays the remembered result instead of moving the money again.

Demo users (all with the password `ledger-demo-2026`, or whatever `DEMO_PASSWORD` was set to when seeding):

| Username | Role | Accounts |
| --- | --- | --- |
| `alice` | customer | `acme-ops`, `acme-payroll`, `acme-tax`, `acme-savings` |
| `bob` | customer | `globex-ops`, `globex-payroll` |
| `admin` | admin | none; sees every account and makes deposits |

These passwords are published here, so they're for local demos only.

The demo data is three months (July to September 2026) of activity for two companies: 37 transfers in all.

- **Money coming in:** client payments into `acme-ops` and `globex-ops`.
- **Regular costs:** monthly payroll funding and payroll runs, rent and software subscriptions.
- **Moving money around:** a 15% tax set-aside into `acme-tax`, savings transfers, Acme paying Globex's invoices, and a Q3 estimated tax payment in September.

| Account | Balance after seeding |
| --- | --- |
| `acme-ops` | $28,253.00 |
| `acme-payroll` | $1,500.00 |
| `acme-savings` | $6,000.00 |
| `acme-tax` | $4,160.00 |
| `external` | -$75,013.00 |
| `globex-ops` | $34,500.00 |
| `globex-payroll` | $600.00 |

`external` is negative because it's where money enters and leaves the ledger. All balances always sum to zero. The data is defined in [`backend/src/Ledger/Seed.hs`](backend/src/Ledger/Seed.hs).

If `ledger-seed` stops with "exists but isn't owned by", your database was seeded before users existed. Reset it as below.

To wipe everything and start again:

```sh
docker compose down -v && docker compose up -d
cabal run ledger-seed
```

### 3. Run the API

```sh
cabal run ledger-api   # with DATABASE_URL still set
# Using the Postgres store (add demo data with: cabal run ledger-seed)
# Ledger API listening on http://localhost:8080
```

On startup the API applies any new migrations and makes sure the `external` account exists. It never adds demo data to a database by itself, so pointing it at a real database can't create fake money.

Without `DATABASE_URL`, `cabal run ledger-api` uses the in-memory store and fills it with the same demo users and data. That needs no Docker, but the data is lost on restart.

| Variable | What it does |
| --- | --- |
| `DATABASE_URL` | Use this Postgres database. Unset: in-memory with demo data. |
| `PORT` | Port to listen on. Default 8080. |
| `COOKIE_SECURE` | Set to `true` to mark the session cookie HTTPS-only. Leave unset for `http://localhost`; always set it in a real deployment. |
| `DEMO_PASSWORD` | Password for demo users created by the in-memory mode or `ledger-seed`. Default `ledger-demo-2026`. |

### 4. Look at the data

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
SELECT key, transfer_id, error FROM idempotency_keys; -- remembered outcomes, keys prefixed by user
SELECT username, role FROM users;
SELECT username, expires_at FROM sessions;            -- logged-in browsers
```

### Changing the database schema

Add a new file to `backend/db/migrations`, numbered after the last one (for example `0003_add_statements.sql`), and add it to the `migrationFiles` list in [`backend/src/Ledger/Db.hs`](backend/src/Ledger/Db.hs). The API and `ledger-seed` apply it on their next start. Never edit a migration that has already been applied; add a new one instead. `MigrationsSpec` fails if a file is missing from the list.

### Coming in later steps

```sh
# Front end on http://localhost:5173, in a second terminal
cd web
npm install
npm run dev
```

In development, Vite will proxy `/api` requests to the Haskell server, so no CORS setup is needed.

## Try it

With the API running, use `curl` as below, or open [`backend/api.http`](backend/api.http) in VS Code with the [REST Client](https://marketplace.visualstudio.com/items?itemName=humao.rest-client) extension and click **Send Request** above each block. REST Client keeps the session cookie between requests, like a browser.

`curl` keeps cookies in a file: `-c` saves them, `-b` sends them.

```sh
# Log in as alice; the session cookie goes into alice.txt
curl -c alice.txt localhost:8080/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username": "alice", "password": "ledger-demo-2026"}'

# Alice's accounts and balances (only hers)
curl -b alice.txt localhost:8080/api/accounts

# Move $1,500 with an idempotency key. Run it twice: the same transfer comes
# back both times and the money moves only once.
curl -b alice.txt localhost:8080/api/transfers \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: payroll-1' \
  -d '{"from": "acme-ops", "to": "acme-payroll", "amountCents": 150000, "memo": "September payroll"}'

# Try to overdraw: 422 insufficient_funds
curl -b alice.txt localhost:8080/api/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from": "acme-payroll", "to": "acme-ops", "amountCents": 99999999}'

# Try to send from bob's account: 404, as if it didn't exist
curl -b alice.txt localhost:8080/api/transfers \
  -H 'Content-Type: application/json' \
  -d '{"from": "globex-ops", "to": "acme-ops", "amountCents": 100}'

# The double-entry view of one account
curl -b alice.txt localhost:8080/api/accounts/acme-payroll/entries

# Log out: the cookie stops working
curl -b alice.txt -X POST localhost:8080/api/logout
```

## API

Every endpoint except `/api/health` and `/api/login` needs a logged-in session (the `ledger_session` cookie that login sets).

| Method | Path | Who | Description | Success |
| --- | --- | --- | --- | --- |
| `GET` | `/api/health` | anyone | Health check | 200 |
| `POST` | `/api/login` | anyone | Log in: `{ "username", "password" }`. Sets the session cookie and returns `{ "username", "role" }`. | 200 |
| `POST` | `/api/logout` | anyone | End the session and clear the cookie | 204 |
| `GET` | `/api/me` | logged in | The logged-in user: `{ "username", "role" }` | 200 |
| `GET` | `/api/accounts` | logged in | Accounts you can see, with balances: your own, or all of them for an admin | 200 |
| `POST` | `/api/accounts` | logged in | Open an account: `{ "id", "name", "owner"? }`. `owner` defaults to you; only an admin may name someone else. | 201 |
| `GET` | `/api/accounts/:id` | owner or admin | One account with its balance | 200 |
| `GET` | `/api/accounts/:id/entries` | owner or admin | An account's ledger entries, newest first | 200 |
| `POST` | `/api/deposits` | admin | Deposit from outside: `{ "to", "amountCents" }` | 201 |
| `POST` | `/api/transfers` | owner of `from` | Transfer: `{ "from", "to", "amountCents", "memo"? }`, optional `Idempotency-Key` header. `to` can be anyone's account. | 201 |

An account you can't see answers 404, exactly like one that doesn't exist, so the API never reveals which accounts other people have.

Amounts are integer cents: `150000` is $1,500.00. One transfer can move at most $1,000,000,000.00 (`100000000000`).

Input rules:

| Field | Rule |
| --- | --- |
| Account `id` | 1 to 64 characters: lowercase letters, digits and `-` (ids appear in URLs) |
| Account `name` | 1 to 100 characters |
| `memo` | Optional, at most 500 characters |
| `Idempotency-Key` header | 1 to 255 visible ASCII characters, no spaces. A UUID works well. |
| Request body | At most 64 KB |

Errors come back as `{ "error": "<code>", "message": "<text>" }`:

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad_request` | The body isn't valid JSON or is missing a field |
| 400 | `invalid_amount` | `amountCents` is zero, negative, or over the maximum |
| 400 | `invalid_account_id` | The account id breaks the rules above |
| 400 | `invalid_account_name` | The account name is empty or too long |
| 400 | `invalid_memo` | The memo is too long |
| 400 | `invalid_idempotency_key` | The `Idempotency-Key` header is empty, too long, or has spaces |
| 401 | `unauthorized` | Not logged in, or the session has expired or ended |
| 401 | `invalid_credentials` | Wrong username or password (the same answer for both, so it doesn't reveal which usernames exist) |
| 403 | `forbidden` | Logged in, but not allowed: a customer depositing, sending from an account they don't own, or opening an account for someone else |
| 404 | `unknown_account` | An account in the request doesn't exist, or you can't see it |
| 404 | `unknown_user` | An admin opening an account for a user that doesn't exist |
| 404 | `not_found` | No endpoint at that URL |
| 409 | `account_exists` | Opening an account with an id that's taken |
| 409 | `idempotency_key_reused` | The same `Idempotency-Key` was sent with a different request |
| 413 | `payload_too_large` | The request body is over 64 KB |
| 422 | `same_account` | `from` and `to` are the same account |
| 422 | `insufficient_funds` | The transfer would take a customer account below zero |
| 500 | `internal_error` | Something failed on the server (for example, the database is down). Details are logged on the server, never sent to the client. |

## Security

- **Passwords** are stored only as [Argon2id](https://en.wikipedia.org/wiki/Argon2) hashes, a deliberately slow and memory-hungry algorithm, so a stolen `users` table is expensive to crack. A login for an unknown username still does the same hashing work, so response times don't reveal which usernames exist.
- **Sessions:** logging in creates 32 random bytes as a session token, sent to the browser in a cookie. The database stores only the token's SHA-256 hash, so a stolen `sessions` table can't be turned into working cookies. Sessions last 7 days, and logging out deletes the session on the server.
- **The session cookie** is `HttpOnly` (JavaScript can't read it, so an XSS bug can't steal it) and `SameSite=Lax` (other websites can't make the browser send it with their POST requests, which blocks cross-site request forgery). With `COOKIE_SECURE=true` it's also `Secure`, sent over HTTPS only.
- **Permissions** live in one small pure module, `Ledger.Auth`, and are checked in `Ledger.App` before the store is touched. Accounts you can't see answer 404 rather than 403, so their existence isn't revealed.
- **Idempotency keys are per user.** `payroll-1` from alice and `payroll-1` from bob are different keys, so one user can't replay another's transfer.

Not done yet: rate limiting on `/api/login` (to slow down password guessing), password changes, and sign-up. Demo users are created by `ledger-seed`.

## Progress

- [x] Domain types (`Ledger.Money`, `Ledger.Types`)
- [x] Pure core and STM store
- [x] HTTP layer and executable
- [x] Tests
- [x] PostgreSQL store, migrations, seed data and Docker Compose
- [x] Users, sessions and account ownership
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
    app/Main.hs              # the API server: picks a store, starts the server
    seed/Main.hs             # the ledger-seed command: adds demo data to DATABASE_URL
    src/Ledger/*.hs          # the library (see Design)
    db/migrations/*.sql      # schema changes, applied in order at startup
    test/                    # one *Spec.hs per area, plus shared Support/ modules
    api.http                 # sample requests for the REST Client extension
  web/                       # Vite + React + TypeScript (later step)
  .github/workflows/ci.yml   # CI (later step)
```

Because `cabal.project` sits at the root, `cabal build all` works from either the root or `backend/`.
