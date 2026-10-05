# Haskell Ledger

[![CI](https://github.com/Wallruzz9114/haskell-ledger/actions/workflows/ci.yml/badge.svg)](https://github.com/Wallruzz9114/haskell-ledger/actions/workflows/ci.yml)

A full-stack double-entry ledger: a Haskell API that moves money between accounts and enforces bookkeeping rules, backed by PostgreSQL, with property-based tests and a React + TypeScript + Redux Toolkit front end.

> **Status:** every planned step is done: the API, the Postgres store, user logins, the web front end, CI, and a one-command Docker setup. See [Progress](#progress).
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

## Design decisions

The choices I'd want to talk about, and why I made them.

- **Money is integer cents, and a transfer amount can't be invalid.** `Cents` wraps an `Integer`, so there's no floating-point rounding anywhere, from Postgres to the browser. `Amount` can only be built by `mkAmount`, which rejects zero, negatives and anything over $1B. Every function that takes an `Amount` can rely on that without checking again.
- **The rules live in one pure function.** `Ledger.Core.checkTransfer` decides whether a transfer is allowed, with no database or HTTP involved. The in-memory store and the Postgres store both call it, so there's one copy of the rules and it's easy to test.
- **Storage is an interface.** `LedgerStore` is a record of functions with two implementations: STM in memory for fast tests, and Postgres. Both pass the same contract tests. Only the two programs' `main` functions choose which one to use.
- **Overdrafts are impossible, not just unlikely.** In Postgres, a transfer locks both account rows (`SELECT ... FOR UPDATE`, always in id order, so two opposite transfers can't deadlock) before reading balances. A `CHECK` constraint rejects a negative customer balance even if the code were wrong. A test fires 200 concurrent transfers at one account and checks that exactly the affordable ones succeed.
- **Retries are safe.** An `Idempotency-Key` is claimed in the same transaction as the transfer, and its outcome is remembered, failures included, so a retry gets the same answer. Keys are scoped per user, so nobody can replay someone else's transfer. The front end keeps one key per draft and changes it when the details change.
- **Errors are values.** `applyTransfer` returns `Either TransferError`, not exceptions, and `Ledger.App` turns each error into an HTTP status in one function, so the compiler warns if a new error isn't handled.
- **One set of types for both languages.** The TypeScript types the front end uses are generated from the Haskell ones. Renaming a field breaks the front end's build instead of breaking it at runtime.
- **Tested for properties, not just examples.** QuickCheck runs random sequences of transfers and checks what must always be true: balances sum to zero, no customer goes negative, and every balance equals the sum of its entries.

**Tradeoffs and what I'd do next:**

- **Named outside parties.** Clients and vendors are all one `external` account, so the dashboard's top sources say "External". Real payees would be the next model change.
- **Paging and search in SQL.** The transactions page pages and searches in Haskell over the account's entries. At real volumes that should happen in the database.
- **Shared login limits.** Login limits live in the server's memory, which only works for a single instance. With several instances they'd need to be in Postgres or Redis.
- **Missing features:** sign-up, password changes, and observability (structured logs and metrics).

## How I built this, with Claude Code

This is my first Haskell project. I started from a tutorial (the domain types, the pure core, the HTTP layer) and typed the early steps myself, following the compiler errors. From there I used [Claude Code](https://claude.com/claude-code) as a pair programmer to take it much further than the tutorial: Postgres, logins and permissions, the web app, the dashboard, CI and Docker.

How I worked with it:

- **One pull request per step.** The work was planned in steps, with a branch and a PR for each, and CI required to pass before merging. `main` is protected.
- **Review before merge.** I asked for code reviews and security reviews on the larger PRs, and every finding was fixed or consciously deferred.
- **Reproduce first, then fix, then test.** A bug had to be shown to fail (against the running API, or in a test) before it was fixed, and each fix came with a test that fails without it.
- **Checking the tests themselves.** Several times we removed a fix on purpose to make sure its test really failed.
- **Checking the real thing.** Every feature was also run for real, against the actual API, Postgres, Docker and a headless browser, not just in unit tests.

Some things that happened along the way:

- **An idempotency bug.** A review found that editing a refused transfer and resending it failed with "key already used". We reproduced it against the API, fixed the front end to use a new key when the details change, and added a test.
- **A denial-of-service risk.** Argon2 runs as a blocking C call, so a flood of logins could stall the server. We measured it, limited concurrent password checks, added lockouts, and confirmed a health check still answers in under a millisecond during a 40-login burst.
- **A dependency problem.** A new crypton release broke the Docker build on Apple Silicon. The fix was pinning every dependency with `cabal.project.freeze`, so my laptop, CI and Docker all build the same code.
- **A Haskell lesson from the tests.** A test hung forever because `[0 .. 4]` as `NominalDiffTime` counts in picoseconds.

What I learned about Haskell: modelling a domain with types first and letting the compiler hold everything else to it; smart constructors; `Either` for errors; keeping the core pure and pushing IO to the edges; STM; records of functions as interfaces; Template Haskell (and its stage restriction); property-based testing; and how laziness can surprise you. Every Haskell file has comments written for a beginner, which is how I learned while building.

## Code structure

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
| `Ledger.Throttle` | Login protection: failed-attempt limits per username and per address, and a cap on password checks running at once. |
| `Ledger.Seed` | The `external` account every ledger needs, and the demo users and data. |
| `Ledger.Reports` | The dashboard's numbers and the transactions page's search and paging: pure functions over entries, like `Ledger.Core`. |
| `Ledger.Api` | The shape of every API request and response, with matching TypeScript types generated from the same definitions (see below). |
| `Ledger.App` | HTTP layer (Scotty): logins, permission checks, and the only place domain errors become status codes. |

The API uses Postgres when `DATABASE_URL` is set, and the in-memory store otherwise. Only the two programs' `Main` modules choose a store; nothing else knows which one it's using.

### One set of types for Haskell and TypeScript

The front end doesn't describe the API's JSON by hand. `Ledger.Api` defines every request and response as a Haskell record and derives, from the same settings, both its JSON encoding ([aeson](https://hackage.haskell.org/package/aeson)) and a TypeScript type ([aeson-typescript](https://hackage.haskell.org/package/aeson-typescript)). A small program writes those types to [`web/src/app/generated/apiTypes.ts`](web/src/app/generated/apiTypes.ts), and the front end imports them.

So a change on one side can't silently break the other. Renaming a field in Haskell (`balanceCents` to `balance`, say) and regenerating makes the front end fail to compile, with an error at every place that uses the old name, instead of showing `$NaN` at runtime. If someone changes the Haskell types but forgets to regenerate, a backend test (`TypeScriptSpec`) fails in CI.

After changing a type in `Ledger.Api` (or one it uses), regenerate from the repository root:

```sh
cabal run -v0 ledger-typescript > web/src/app/generated/apiTypes.ts
```

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

The HTTP tests log in as each demo user and check every permission rule and login protection (lockout after repeated failures, per-address limits with and without a trusted proxy, JSON-only bodies, `no-store`, the `Secure` cookie flag): customers see only their own accounts, someone else's account answers 404 as if it didn't exist, nobody can send from an account they don't own (not even an admin), only admins can deposit, logging out ends the session, and one user's idempotency keys can't replay another's transfers.

The Postgres tests run when `TEST_DATABASE_URL` is set, and are marked pending otherwise:

```sh
cd backend
cabal test --test-show-details=direct
# 130 examples, 0 failures, 1 pending

TEST_DATABASE_URL=postgresql://ledger:ledger@localhost:5434/ledger_test \
  cabal test --test-show-details=direct
# 144 examples, 0 failures
```

The tests are split by area under `backend/test`:

| File | What it tests |
| --- | --- |
| `Ledger/AppSpec.hs` | The HTTP API: logging in and out, permissions, status and error codes, input checks, the body size limit, and a JSON 500 that doesn't leak details |
| `Ledger/AuthSpec.hs` | The permission rules in `Ledger.Auth` |
| `Ledger/SessionSpec.hs` | Password hashing (including hashes made by other Argon2 tools) and session tokens |
| `Ledger/ThrottleSpec.hs` | Failed-login limits and the password-check slots |
| `Ledger/UserStoreSpec.hs` | The user store contract against the in-memory store |
| `Ledger/MoneySpec.hs` | `mkAmount` (including the maximum amount) and `formatCents` |
| `Ledger/ValidateSpec.hs` | The rules for account ids and names, memos and idempotency keys |
| `Ledger/ReportsSpec.hs` | Dashboard totals (money in/out ignore transfers between your own accounts), the balance series, search and paging, including QuickCheck properties: the chart always ends at today's total, and paging visits every transaction exactly once |
| `Ledger/MigrationsSpec.hs` | Every SQL file in `db/migrations` is listed in `Ledger.Db` |
| `Ledger/TypeScriptSpec.hs` | The generated TypeScript types match the Haskell ones |
| `Ledger/SeedSpec.hs` | The demo data applies cleanly, keeps every rule, gives each account the right owner, is dated July to September in order, and seeding twice changes nothing |
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

### Front-end tests

The front end has its own Vitest suite (`cd web && npm test`), with one test file next to each piece it tests. The tests replace `fetch` with a fake API, so they need no server:

| File | What it tests |
| --- | --- |
| `src/app/money.test.ts` | Formatting cents and parsing typed amounts, with no floating-point rounding and the API's maximum |
| `src/app/api.test.ts` | Reading error messages and 401s from API responses |
| `src/app/idempotency.test.ts` | Idempotency keys: valid UUIDs, never repeated, and made without `crypto.randomUUID` so plain-HTTP pages work |
| `src/features/dashboard/DashboardPage.test.tsx` | The total, money in/out with names, switching months, reading the chart with the keyboard, and its table view |
| `src/features/dashboard/format.test.ts` | Day and month labels (no time-zone shift), axis labels, and axis ticks that always cover the data |
| `src/features/transactions/TransactionsPage.test.tsx` | Names on both sides, "Load more" sending the cursor, search waiting for typing to pause, and only your own accounts in the filter |
| `src/App.test.tsx` | Logged out shows the login page, logging in shows your accounts, logging out goes back, and an unreachable API offers a retry that works |
| `src/features/auth/LoginPage.test.tsx` | Wrong-password and lockout messages |
| `src/features/accounts/AccountsPanel.test.tsx` | Customers vs admins: what each sees, and balances refreshing when the tab gets focus again |
| `src/features/accounts/AccountEntries.test.tsx` | Each entry's counterparty ("To"/"From"), memo, date and signed amount |
| `src/features/transfers/TransferForm.test.tsx` | Only your own accounts to send from; amounts sent in cents; the same `Idempotency-Key` on an unchanged retry but a new one once the details change (so editing a refused transfer isn't a 409); API errors shown |
| `src/features/transfers/DepositForm.test.tsx` | Deposits: customer accounts only, and the same key rules as transfers |

## Continuous integration

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every pull request and every push to `main`, as three jobs in parallel:

| Job | Checks |
| --- | --- |
| Backend | Build with GHC 9.4.8 and `-Wall`, hlint (no hints allowed), and the whole test suite, including the Postgres tests against a Postgres 16 service container |
| Frontend | `npm ci`, typecheck, oxlint, Prettier, Vitest, and a production build |
| Docker images | Builds the API and web images, so a broken Dockerfile shows up on the PR (layers are cached between runs) |

`main` is protected: GitHub won't merge a pull request into it until all three jobs pass.

Compiled Haskell dependencies are cached between runs, so only the first run (or one after changing the cabal file) compiles them all.

## Tech stack

| Layer | Technology |
| --- | --- |
| Backend | Haskell (GHC 9.4.8), Scotty, STM, aeson |
| Database | PostgreSQL 16, postgresql-simple, resource-pool |
| Tests | hspec, QuickCheck, hspec-wai (backend); Vitest, Testing Library (front end) |
| Frontend | React 19, TypeScript, Redux Toolkit (RTK Query), Vite, oxlint, Prettier |
| Tooling | GHCup, cabal, Docker Compose, Node 22, GitHub Actions |

## Quick start: everything in Docker

Needs only Docker. From the repository root:

```sh
docker compose up -d
```

That builds the images, starts Postgres, adds the demo users and data, and starts the API and the site. Then open <http://localhost:3000> and log in as `alice`, `bob` or `admin` (the demo password is below).

| Service | Address | What it is |
| --- | --- | --- |
| `web` | <http://localhost:3000> | The React app, served by nginx, which forwards `/api` to the API |
| `api` | (internal) | The Haskell API, built from [`backend/Dockerfile`](backend/Dockerfile) |
| `seed` | (runs once) | `ledger-seed`: applies migrations and adds the demo data, then exits. The API starts after it finishes. |
| `db` | `localhost:5434` | Postgres 16 |
| `adminer` | <http://localhost:8081> | A web UI for browsing the database |

The first `docker compose up` builds the API image, which compiles every Haskell dependency, so expect 10 minutes or more. Later builds reuse Docker's cache and only recompile what changed. After changing the code, `docker compose up -d --build` rebuilds and restarts.

The API image is built in two stages: GHC 9.4.8 (installed with ghcup) compiles the programs, and the final image holds just `ledger-api`, `ledger-seed` and the libraries they need, on Debian 12, running as a non-root user. The web image is built the same way: Node builds the app, and nginx serves it.

The seed runs on every `docker compose up`, which is safe: it skips anything already there, so the data isn't duplicated. It's there for local demos; a real deployment wouldn't include the `seed` service, and the API itself never adds demo data.

`docker compose down` stops everything and keeps the data; `docker compose down -v` also deletes the database.

## Running locally

To work on the code, run the API and front end directly and use Docker only for the database.

Requires:

- GHC 9.4.8 and cabal (install both with [GHCup](https://www.haskell.org/ghcup/))
- Docker, for Postgres
- `libpq`, Postgres's C client library, which the Haskell driver links against. On macOS: `brew install libpq` (or any Homebrew `postgresql@XX`).
- Node 22, for the front end
- Optional, for editor support in `backend/test/Spec.hs`: `cabal install hspec-discover`. The Haskell language server needs the `hspec-discover` program on your `PATH`. `cabal build` and `cabal test` don't, because cabal builds it for them.

### 1. Start Postgres

```sh
docker compose up -d db adminer
```

Naming the services starts only the database and its browser, without building the app images. This starts:

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

The demo data is three months (July to September 2026) of activity for two companies: 37 transfers in all, each dated on its own day during business hours, so the entries view reads like a real history.

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

If a demo account already exists without an owner (a database seeded before users existed), `ledger-seed` gives it its owner. It stops only if a demo account belongs to someone else, which means the database holds other data.

To wipe everything and start again:

```sh
docker compose down -v && docker compose up -d db adminer
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
| `COOKIE_SECURE` | When the session cookie is marked `Secure` (HTTPS only). Unset: whenever the request came over HTTPS, directly or via a proxy sending `X-Forwarded-Proto: https`, which suits both a real deployment and `http://localhost`. `true` or `false` forces it on or off. |
| `TRUST_PROXY` | Set to `true` when the API sits behind a reverse proxy that sets `X-Forwarded-For`. Login limits per address then use the client's real address instead of the proxy's. Leave unset when clients connect directly, or a client could fake the header. |
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

### 5. Run the front end

With the API running on port 8080, in a second terminal:

```sh
cd web
npm install
npm run dev
# ➜  Local:   http://localhost:5173/
```

Open <http://localhost:5173> and log in as one of the demo users:

- **alice** or **bob** see only their own accounts, can send money from them to any account id (for example alice paying `globex-ops`), and can open new accounts for themselves.
- **admin** sees every account with its owner, makes deposits, opens accounts for users, and assigns owners. Admins can't send money out of customers' accounts, so there's no transfer form.

The app has three pages. **Dashboard** leads with your total balance and a 90-day balance chart (hover it, or use the arrow keys), then the month's money in and money out with top sources and spending; switch months with ‹ ›. **Transactions** lists everything across your accounts with names on both sides, a search box, an account filter and "Load more". **Accounts** is where you move money: click an account to see its double-entry history: when each transfer happened, who was on the other side, the memo, and the amount. Balances refresh by themselves when you come back to the tab or your connection returns, so a payment made elsewhere shows up without reloading. If the API can't be reached, the page says so and offers **Try again**. Vite forwards `/api` requests to the Haskell server, so the browser only ever talks to one origin: the session cookie just works, and there's no CORS to set up.

Front-end commands, from `web/`:

| Command | What it does |
| --- | --- |
| `npm run dev` | Development server with hot reload |
| `npm test` | Run the Vitest tests once (`npm run test:watch` to keep watching) |
| `npm run typecheck` | TypeScript type check |
| `npm run lint` | oxlint |
| `npm run format` | Prettier (`format:check` to check without changing files) |
| `npm run build` | Production build into `web/dist` |

### Upgrading a database from before users existed

Accounts opened before migration `0002` have no owner. Nobody can use them until they get one: customers can't see them and nobody can send from them. The API lists any such accounts when it starts:

```text
Warning: 1 customer account(s) have no owner, so nobody can use them:
  legacy-ops
```

An admin assigns an owner with `PUT /api/accounts/:id/owner`:

```sh
curl -b admin.txt -X PUT localhost:8080/api/accounts/legacy-ops/owner \
  -H 'Content-Type: application/json' -d '{"owner": "bob"}'
```

### Dependencies are pinned

[`cabal.project.freeze`](cabal.project.freeze) records the exact version of every Haskell dependency, so your machine, CI and the Docker image all build the same code. Without it, each build picks the newest versions allowed, and a new release can break one of them. That already happened once: crypton 2.x added ARM-specific C code that GCC on ARM Linux can't compile, which broke the Docker build on Apple Silicon. The cabal file now holds crypton at 1.1 for that reason.

After changing `build-depends` in the cabal file, update the pins from the repository root:

```sh
cabal freeze --enable-tests
```

### Changing the database schema

Add a new file to `backend/db/migrations`, numbered after the last one (for example `0003_add_statements.sql`), and add it to the `migrationFiles` list in [`backend/src/Ledger/Db.hs`](backend/src/Ledger/Db.hs). The API and `ledger-seed` apply it on their next start. Never edit a migration that has already been applied; add a new one instead. `MigrationsSpec` fails if a file is missing from the list.

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
| `GET` | `/api/accounts/:id/entries` | owner or admin | An account's ledger entries, newest first (see below) | 200 |
| `GET` | `/api/dashboard` | logged in | Total balance, a daily balance series (`?days=`, default 90) and the month's money in/out with top sources and spending (`?month=2026-09`, default this month), over your accounts (every customer account for an admin) | 200 |
| `GET` | `/api/transactions` | logged in | Your transactions across accounts, newest first, 25 at a time: `?q=` searches memos and names, `?account=` filters, `?before=<nextCursor>` gets the next page | 200 |
| `PUT` | `/api/accounts/:id/owner` | admin | Give a customer account an owner: `{ "owner" }` | 200 |
| `POST` | `/api/deposits` | admin | Deposit from outside: `{ "to", "amountCents" }` | 201 |
| `POST` | `/api/transfers` | owner of `from` | Transfer: `{ "from", "to", "amountCents", "memo"? }`, optional `Idempotency-Key` header. `to` can be anyone's account. | 201 |

Request bodies must be sent with `Content-Type: application/json`.

Each entry is one side of a transfer, seen from that account:

```json
{
  "transfer": 40,
  "account": "acme-ops",
  "amount": -1234,
  "counterparty": "globex-ops",
  "memo": "Coffee beans for the office",
  "createdAt": "2026-09-29T19:14:03.512Z"
}
```

`amount` is negative when money left the account. `counterparty` is the account on the other side, and `createdAt` is when the transfer happened, in UTC. Transfers returned by `POST /api/transfers` and `/api/deposits` also include `createdAt`.

An account you can't see answers 404, exactly like one that doesn't exist, so reading an account never reveals that someone else has it.

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
| 400 | `invalid_month`, `invalid_days`, `invalid_limit`, `invalid_cursor` | A dashboard or transactions query parameter is malformed |
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
| 415 | `unsupported_media_type` | The request body wasn't sent as `application/json` |
| 422 | `same_account` | `from` and `to` are the same account |
| 422 | `insufficient_funds` | The transfer would take a customer account below zero |
| 422 | `system_account` | Trying to give a system account (like `external`) an owner |
| 429 | `too_many_attempts` | Too many failed logins for that username (5 per 15 minutes) or from that address (30 per 15 minutes). `Retry-After` says when to try again. |
| 500 | `internal_error` | Something failed on the server (for example, the database is down). Details are logged on the server, never sent to the client. |
| 503 | `login_busy` | Every password-check slot is busy (see [Security](#security)). `Retry-After: 1`. |

## Security

- **Passwords** are stored only as [Argon2id](https://en.wikipedia.org/wiki/Argon2) hashes (64 MB of memory, 2 passes, a random salt each), a deliberately slow and memory-hungry algorithm, so a stolen `users` table is expensive to crack. They use the standard PHC text format, so other Argon2 tools can read them. A login for an unknown username still does the same hashing work, so response times don't reveal which usernames exist.
- **Login protection.** Checking a password takes about 50 ms of a CPU core and 64 MB of memory, so logins are limited in two ways:
  - **Failed attempts:** 5 wrong passwords for one username, or 30 from one network address, within 15 minutes, and further attempts get `429` without any hashing until the window passes. This also stops password guessing.
  - **Checks at once:** at most 2 password checks run at the same time. Others get `503 login_busy` straight away instead of queueing, so a flood of logins can't use up the server's memory or cores. The server runs on every core (`-N`), so normal requests carry on during a flood. In a test with 40 simultaneous logins, a health check was still answered in under a millisecond.

  The counts live in the server's memory: they're per process and reset on restart. Several servers behind a load balancer would need a shared store for them. Behind a reverse proxy, set `TRUST_PROXY=true` so addresses come from `X-Forwarded-For`; otherwise every user seems to share the proxy's address.
- **Sessions:** logging in creates 32 random bytes as a session token, sent to the browser in a cookie. The database stores only the token's SHA-256 hash, so a stolen `sessions` table can't be turned into working cookies. Sessions last 7 days, logging out deletes the session on the server, and expired sessions are cleaned up.
- **The session cookie** is `HttpOnly` (JavaScript can't read it, so an XSS bug can't steal it) and `SameSite=Lax` (other websites can't make the browser send it with their POST requests). It's `Secure` (HTTPS only) whenever the request came over HTTPS, without any setting to remember.
- **Cross-site request forgery.** Besides `SameSite=Lax`, request bodies must be `application/json`. A form on another website can't send that without the browser asking this server first, which it never allows. That still holds where `SameSite` doesn't help, for example from a sibling subdomain.
- **No caching.** Every response carries `Cache-Control: no-store`, so browsers and shared proxies don't keep copies of account data.
- **Permissions** live in one small pure module, `Ledger.Auth`, and are checked in `Ledger.App` before the store is touched. Customers' account lists are filtered by the database.
- **Idempotency keys are per user.** They're stored as `user:<name>:<key>`, so `payroll-1` from alice and from bob are different keys, and neither can collide with the seed's `seed:...` keys.

Known limits:

- **Account ids can be discovered.** Ids are unique across the whole ledger, and you can pay any account. So opening an account with a taken id answers `409 account_exists`, and a transfer to an id that doesn't exist answers `404`. Someone logged in can use that to check whether an id exists, though not what's in the account. Per-user account ids or payee lists would close this.
- Not done yet: password changes, sign-up, and a shared store for login limits across several servers. Demo users are created by `ledger-seed`.

## Progress

- [x] Domain types (`Ledger.Money`, `Ledger.Types`)
- [x] Pure core and STM store
- [x] HTTP layer and executable
- [x] Tests
- [x] PostgreSQL store, migrations, seed data and Docker Compose
- [x] Users, sessions and account ownership
- [x] Front end
- [x] CI
- [x] Run the whole app with `docker compose up`

## Repository layout

```text
haskell-ledger/
  cabal.project              # points cabal and the editor at backend/
  cabal.project.freeze       # the exact version of every Haskell dependency
  docker-compose.yml         # the whole app: web, api, Postgres and Adminer
  .dockerignore              # keeps the Docker build context small
  backend/
    double-entry-ledger.cabal
    Dockerfile               # builds the API image (ledger-api and ledger-seed)
    app/Main.hs              # the API server: picks a store, starts the server
    seed/Main.hs             # the ledger-seed command: adds demo data to DATABASE_URL
    typegen/Main.hs          # the ledger-typescript command: writes the front end's API types
    src/Ledger/*.hs          # the library (see Design)
    db/migrations/*.sql      # schema changes, applied in order at startup
    db/docker-init/          # run by the Postgres container on first start: creates ledger_test
    test/                    # one *Spec.hs per area, plus shared Support/ modules
    api.http                 # sample requests for the REST Client extension
  web/                       # Vite + React + TypeScript front end
    Dockerfile               # builds the app with Node, serves it with nginx
    nginx.conf               # serves the app, forwards /api to the api service
    src/app/                 # API client (RTK Query), Redux store, money helpers
    src/app/generated/       # API types generated from Haskell (don't edit by hand)
    src/features/            # auth, dashboard, transactions, accounts and transfers, each with its tests
    src/index.css            # styles
  .github/workflows/ci.yml   # CI: build, lint and test both halves on every PR
```

Because `cabal.project` sits at the root, `cabal build all` works from either the root or `backend/`.
