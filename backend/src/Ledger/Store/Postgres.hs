{-# LANGUAGE OverloadedStrings #-}

-- | The Postgres implementation of 'LedgerStore': the same record of
-- functions as the in-memory store, backed by real tables that survive a
-- restart. Callers (Ledger.App, the tests) can't tell the two apart.
--
-- The money rules are NOT rewritten here. We load the two accounts, then ask
-- Ledger.Core.checkTransfer, the same pure function the in-memory store uses.
--
-- How concurrency is kept safe, compared with the in-memory store:
--
--   In-memory (STM): the whole transfer is one "atomically" block; if two
--   overlap, STM re-runs one of them against the new state.
--
--   Postgres: the whole transfer is one database transaction, and it LOCKS
--   the two account rows ("SELECT ... FOR UPDATE") before reading balances.
--   A second transfer touching the same account waits at that line until
--   the first commits, then reads the new balance. The CHECK constraint on
--   accounts.balance is a last line of defence if the code ever got it wrong.
module Ledger.Store.Postgres
  ( newPostgresStore
  ) where

import Data.Aeson (Result (..), Value, fromJSON, toJSON)
import Data.Pool (Pool, withResource)
import Data.Text (Text)
import Database.PostgreSQL.Simple
import Ledger.Core (checkTransfer)
import Ledger.Money (Cents (..), unAmount)
import Ledger.Store (LedgerStore (..))
import Ledger.Types

-- | Build a store that borrows connections from this pool.
--
-- Unlike newInMemoryStore this isn't an IO action: there's nothing to
-- create, since the data already lives in the database.
newPostgresStore :: Pool Connection -> LedgerStore
newPostgresStore pool =
  LedgerStore
    { storeOpenAccount = \aid name kind -> withConn $ \conn -> do
        -- "ON CONFLICT DO NOTHING" makes a duplicate id insert zero rows
        -- instead of raising an error; execute returns the row count.
        inserted <-
          execute
            conn
            "INSERT INTO accounts (id, name, kind) VALUES (?, ?, ?) ON CONFLICT (id) DO NOTHING"
            (accountIdText aid, name, kindText kind)
        pure $
          if inserted == 1
            then Right (Account aid name kind)
            else Left (AccountAlreadyExists aid)
    , storeGetAccount = \aid -> withConn $ \conn -> do
        rows <- query conn "SELECT id, name, kind, balance FROM accounts WHERE id = ?" (Only (accountIdText aid))
        -- A list pattern: exactly one row -> found; anything else -> Nothing.
        pure $ case rows of
          [row] -> Just (accountRow row)
          _ -> Nothing
    , storeListAccounts = withConn $ \conn ->
        map accountRow <$> query_ conn "SELECT id, name, kind, balance FROM accounts ORDER BY id"
    , storeEntries = \aid -> withConn $ \conn -> do
        -- Distinguish "no such account" (Nothing) from "no entries yet"
        -- (Just []), the same as the in-memory store.
        exists <- query conn "SELECT 1 FROM accounts WHERE id = ?" (Only (accountIdText aid)) :: IO [Only Int]
        if null exists
          then pure Nothing
          else do
            rows <-
              query
                conn
                "SELECT transfer_id, account_id, amount FROM entries WHERE account_id = ? ORDER BY id DESC"
                (Only (accountIdText aid))
            pure (Just [Entry (TransferId t) (AccountId a) (Cents n) | (t, a, n) <- rows])
    , storeTransfer = \mkey req -> withConn $ \conn ->
        -- One transaction for everything: the idempotency check, the rules,
        -- the writes, and remembering the outcome. All of it commits, or
        -- none of it does.
        withTransaction conn $
          case mkey of
            Nothing -> transferIn conn req
            Just key -> do
              -- Claim the key. If another request already holds it, this
              -- inserts nothing (and if that request hasn't committed yet,
              -- Postgres makes us WAIT here until it does).
              claimed <-
                execute
                  conn
                  "INSERT INTO idempotency_keys (key, from_account, to_account, amount, memo) \
                  \VALUES (?, ?, ?, ?, ?) ON CONFLICT (key) DO NOTHING"
                  (keyText key, accountIdText (reqFrom req), accountIdText (reqTo req), amountOf req, reqMemo req)
              if claimed == 1
                then do
                  -- New key: do the transfer, then record how it went.
                  outcome <- transferIn conn req
                  let (tid, err) = case outcome of
                        Right t -> (Just (transferIdNumber t), Nothing)
                        Left e -> (Nothing, Just (toJSON e))
                  _ <- execute conn "UPDATE idempotency_keys SET transfer_id = ?, error = ? WHERE key = ?" (tid, err, keyText key)
                  pure outcome
                else replay conn key req
    }
  where
    -- Borrow a connection for the length of one operation.
    withConn :: (Connection -> IO a) -> IO a
    withConn = withResource pool

-- | Validate and apply one transfer inside an open transaction.
transferIn :: Connection -> TransferRequest -> IO (Either TransferError Transfer)
transferIn conn req = do
  -- Lock both account rows. "ORDER BY id" makes every transfer lock rows in
  -- the same order, so two transfers going opposite ways (A->B and B->A)
  -- can't each hold one lock while waiting for the other (a deadlock).
  -- "In [...]" expands to a SQL list: WHERE id IN ('a', 'b').
  rows <-
    query
      conn
      "SELECT id, name, kind, balance FROM accounts WHERE id IN ? ORDER BY id FOR UPDATE"
      (Only (In [accountIdText (reqFrom req), accountIdText (reqTo req)]))
  let accounts = map accountRow rows
      find aid = lookup aid [(accountId a, (a, bal)) | (a, bal) <- accounts]
      mFrom = find (reqFrom req)
      fromBalance = maybe 0 snd mFrom
  -- The same pure rules as the in-memory store.
  case checkTransfer req (fst <$> mFrom) (fst <$> find (reqTo req)) fromBalance of
    Left err -> pure (Left err)
    Right () -> do
      let amount = amountOf req
          from = accountIdText (reqFrom req)
          to = accountIdText (reqTo req)
      -- RETURNING hands back the id Postgres generated for the new row.
      [Only tid] <-
        query
          conn
          "INSERT INTO transfers (from_account, to_account, amount, memo) VALUES (?, ?, ?, ?) RETURNING id"
          (from, to, amount, reqMemo req)
      -- executeMany runs one INSERT for each tuple in the list.
      _ <-
        executeMany
          conn
          "INSERT INTO entries (transfer_id, account_id, amount) VALUES (?, ?, ?)"
          [(tid, from, negate amount), (tid, to, amount)]
      _ <- execute conn "UPDATE accounts SET balance = balance - ? WHERE id = ?" (amount, from)
      _ <- execute conn "UPDATE accounts SET balance = balance + ? WHERE id = ?" (amount, to)
      pure (Right (Transfer (TransferId tid) (reqFrom req) (reqTo req) (Cents amount) (reqMemo req)))

-- | The key was used before: answer with the remembered outcome if this is
-- the same request, or refuse if it's a different one.
replay :: Connection -> IdempotencyKey -> TransferRequest -> IO (Either TransferError Transfer)
replay conn key req = do
  [(from, to, amount, memo, mTid, mErr)] <-
    query
      conn
      "SELECT from_account, to_account, amount, memo, transfer_id, error FROM idempotency_keys WHERE key = ?"
      (Only (keyText key))
  let sameRequest =
        from == accountIdText (reqFrom req)
          && to == accountIdText (reqTo req)
          && amount == amountOf req
          && memo == reqMemo req
  if not sameRequest
    then pure (Left IdempotencyKeyReused)
    else case (mTid, mErr) of
      (Just tid, _) -> Right <$> loadTransfer conn tid
      (Nothing, Just err) -> pure (Left (decodeError err))
      -- Can't happen: the outcome is saved in the same transaction that
      -- claimed the key, so a committed key always has one.
      (Nothing, Nothing) -> fail ("idempotency key has no outcome: " <> show (keyText key))
  where
    decodeError :: Value -> TransferError
    decodeError v = case fromJSON v of
      Success e -> e
      Error msg -> error ("stored transfer error can't be decoded: " <> msg)

loadTransfer :: Connection -> Integer -> IO Transfer
loadTransfer conn tid = do
  [(from, to, amount, memo)] <-
    query conn "SELECT from_account, to_account, amount, memo FROM transfers WHERE id = ?" (Only tid)
  pure (Transfer (TransferId tid) (AccountId from) (AccountId to) (Cents amount) memo)

-- Converting between Haskell values and database columns --------------------

-- | A row from the accounts table, as (Account, balance).
accountRow :: (Text, Text, Text, Integer) -> (Account, Cents)
accountRow (aid, name, kind, balance) = (Account (AccountId aid) name (kindFromText kind), Cents balance)

kindText :: AccountKind -> Text
kindText Customer = "customer"
kindText External = "external"

kindFromText :: Text -> AccountKind
kindFromText "external" = External
-- The CHECK constraint guarantees the only other value is 'customer'.
kindFromText _ = Customer

accountIdText :: AccountId -> Text
accountIdText (AccountId t) = t

keyText :: IdempotencyKey -> Text
keyText (IdempotencyKey t) = t

amountOf :: TransferRequest -> Integer
amountOf req = let Cents n = unAmount (reqAmount req) in n

transferIdNumber :: Transfer -> Integer
transferIdNumber t = let TransferId n = transferId t in n
