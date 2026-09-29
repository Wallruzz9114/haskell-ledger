-- The ledger schema. Applied once, in order, by Ledger.Db.runMigrations.
-- Never edit a migration that has already been applied: add a new file.
--
-- The Haskell code already enforces every rule below. The database enforces
-- them again, so a bug (or someone running SQL by hand) can't corrupt money.

CREATE TABLE accounts (
  id         text PRIMARY KEY,
  name       text NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('customer', 'external')),
  -- Integer cents, never floating point. bigint holds up to ~92 quadrillion
  -- dollars' worth of cents.
  balance    bigint NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  -- The overdraft rule, as a constraint: customers can't go below zero.
  CONSTRAINT customer_balance_not_negative CHECK (kind = 'external' OR balance >= 0)
);

CREATE TABLE transfers (
  id           bigserial PRIMARY KEY,
  from_account text NOT NULL REFERENCES accounts (id),
  to_account   text NOT NULL REFERENCES accounts (id),
  amount       bigint NOT NULL CHECK (amount > 0),
  memo         text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (from_account <> to_account)
);

-- Double-entry: each transfer writes one negative and one positive entry.
CREATE TABLE entries (
  id          bigserial PRIMARY KEY,
  transfer_id bigint NOT NULL REFERENCES transfers (id),
  account_id  text NOT NULL REFERENCES accounts (id),
  amount      bigint NOT NULL CHECK (amount <> 0),
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- "An account's entries, newest first" is the main read pattern.
CREATE INDEX entries_account_newest_first ON entries (account_id, id DESC);

-- Every transfer's entries must sum to zero. Checked at COMMIT (DEFERRED),
-- because the two entries are inserted one at a time: after the first
-- insert the sum isn't zero yet, and that's fine until the transaction ends.
CREATE FUNCTION check_transfer_balances() RETURNS trigger AS $$
BEGIN
  IF (SELECT sum(amount) FROM entries WHERE transfer_id = NEW.transfer_id) <> 0 THEN
    RAISE EXCEPTION 'entries for transfer % do not sum to zero', NEW.transfer_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER entries_sum_to_zero
  AFTER INSERT ON entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION check_transfer_balances();

-- Requests made with an Idempotency-Key. The request itself is stored so a
-- key reused with a different request can be rejected. No foreign keys on
-- the account columns: a request for an unknown account is still remembered
-- (its outcome is the UnknownAccount error).
CREATE TABLE idempotency_keys (
  key          text PRIMARY KEY,
  from_account text NOT NULL,
  to_account   text NOT NULL,
  amount       bigint NOT NULL,
  memo         text NOT NULL,
  -- The remembered outcome: a transfer on success, or the error as JSON.
  transfer_id  bigint REFERENCES transfers (id),
  error        jsonb,
  created_at   timestamptz NOT NULL DEFAULT now()
);
