{-# LANGUAGE OverloadedStrings #-}

-- | The Postgres store must pass the same store contract as the in-memory
-- one, against a real database.
--
-- These tests need a database they're allowed to wipe, so they only run
-- when TEST_DATABASE_URL points at one ("docker compose up -d" creates
-- "ledger_test" for this). Otherwise they show as pending, not failed.
module Ledger.Store.PostgresSpec (spec) where

import qualified Data.ByteString.Char8 as BS
import Data.List (isSuffixOf)
import Data.Pool (Pool, withResource)
import Database.PostgreSQL.Simple (Connection, Only (..), execute_, query_)
import Ledger.Db (newDbPool, runMigrations)
import Ledger.Store (LedgerStore)
import Ledger.Store.Postgres (newPostgresStore)
import Support.StoreContract (storeContract)
import System.Environment (lookupEnv)
import Test.Hspec

spec :: Spec
spec = do
  -- runIO runs an IO action while hspec is BUILDING the list of tests,
  -- before any test runs. Here: read the env var and, if it's set, connect
  -- and apply migrations once for the whole file.
  -- "traverse" runs the setup only if the Maybe is a Just.
  mPool <- runIO (lookupEnv "TEST_DATABASE_URL" >>= traverse connect)
  case mPool of
    Just pool -> storeContract (emptyStore pool)
    Nothing ->
      it "runs when TEST_DATABASE_URL is set" $
        pendingWith "start Postgres with docker compose and set TEST_DATABASE_URL (see README)"

-- | Connect, refusing any database whose name doesn't end in "_test".
-- These tests empty every table, so pointing TEST_DATABASE_URL at the dev
-- database by mistake would wipe it. Better to stop with a clear message.
connect :: String -> IO (Pool Connection)
connect url = do
  pool <- newDbPool (BS.pack url)
  [Only name] <- withResource pool $ \conn -> query_ conn "SELECT current_database()"
  if "_test" `isSuffixOf` name
    then do
      _ <- runMigrations pool
      pure pool
    else fail ("TEST_DATABASE_URL points at database " <> show name <> ", whose name doesn't end in _test. Refusing to wipe it.")

-- | Wipe every table, then hand back a store over the now-empty database.
-- RESTART IDENTITY resets the id counters, so transfer ids start at 1 again.
emptyStore :: Pool Connection -> IO LedgerStore
emptyStore pool = do
  _ <-
    withResource pool $ \conn ->
      execute_ conn "TRUNCATE accounts, transfers, entries, idempotency_keys RESTART IDENTITY CASCADE"
  pure (newPostgresStore pool)
