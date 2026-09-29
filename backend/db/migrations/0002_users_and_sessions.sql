-- Users, who owns which account, and login sessions.

CREATE TABLE users (
  -- Same shape as account ids: short, lowercase, URL-safe.
  username      text PRIMARY KEY CHECK (username ~ '^[a-z0-9-]{1,32}$'),
  -- An Argon2 hash (salt and settings included), never the password itself.
  password_hash text NOT NULL,
  role          text NOT NULL CHECK (role IN ('customer', 'admin')),
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Who owns each account. NULL for system accounts like "external", which
-- nobody may send money from.
ALTER TABLE accounts ADD COLUMN owner text REFERENCES users (username);
CREATE INDEX accounts_by_owner ON accounts (owner);

-- One row per logged-in browser. The cookie holds a random token; only its
-- SHA-256 hash is stored, so a leaked copy of this table can't be used to
-- log in as anyone.
CREATE TABLE sessions (
  token_hash bytea PRIMARY KEY,
  username   text NOT NULL REFERENCES users (username) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);
CREATE INDEX sessions_by_username ON sessions (username);
