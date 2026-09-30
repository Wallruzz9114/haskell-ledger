{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError, execute_, query_)
import Ledger.Db (newDbPool, runMigrations)
import Control.Monad (void)
import Ledger.Store (LedgerStore (..), StoreUnavailable, UserStore (..))
import Ledger.Types (Role (..), User (..), Username)
import Ledger.Store.Postgres (newPostgresStore, newPostgresUserStore, usingPool)
import Support.StoreContract (storeContract)
import Support.UserStoreContract (userStoreContract)
import System.Environment (lookupEnv)
import Test.Hspec

spec :: Spec
spec = do
  -- No database needed: nothing listens on port 1.
  describe "when the database can't be reached" $
    it "reports StoreUnavailable, not a raw driver error" $ do
      pool <- newDbPool "postgresql://ledger:ledger@localhost:1/ledger"
      storeListAccounts (newPostgresStore pool) `shouldThrow` isUnavailable

  -- runIO runs an IO action while hspec is BUILDING the list of tests,
  -- before any test runs. Here: read the env var and, if it's set, connect
  -- and apply migrations once for the whole file.
  -- "traverse" runs the setup only if the Maybe is a Just.
  mPool <- runIO (lookupEnv "TEST_DATABASE_URL" >>= traverse connect)
  case mPool of
    Just pool -> do
      describe "ledger store" (storeContract (emptyStore pool))
      describe "failures" $ do
        it "cancels a query that runs past the 5-second statement timeout" $ do
          let slowQuery = usingPool pool $ \conn -> query_ conn "SELECT pg_sleep(6)" :: IO [Only ()]
          slowQuery `shouldThrow` isUnavailable
        it "passes other SQL errors through: they're bugs, not outages" $ do
          let badQuery = usingPool pool $ \conn -> query_ conn "SELECT * FROM no_such_table" :: IO [Only Int]
          badQuery `shouldThrow` (\(_ :: SqlError) -> True)
      describe "user store" (userStoreContract (emptyUserStore pool))
    Nothing ->
      it "runs when TEST_DATABASE_URL is set" $
        pendingWith "start Postgres with docker compose and set TEST_DATABASE_URL (see README)"

-- | Connect, refusing any database whose name doesn't end in "_test".
-- These tests empty every table, so pointing TEST_DATABASE_URL at the dev
-- database by mistake would wipe it. Better to stop with a clear message.
-- | shouldThrow takes a predicate on the exception; this one accepts any
-- StoreUnavailable.
isUnavailable :: Selector StoreUnavailable
isUnavailable _ = True

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
emptyStore :: Pool Connection -> IO (LedgerStore, Username -> IO ())
emptyStore pool = do
  wipe pool
  -- Accounts can only be owned by users that exist (a foreign key), so the
  -- contract gets a way to create them.
  let createUser name = void (storeCreateUser (newPostgresUserStore pool) (User name RoleCustomer) "not-a-real-hash")
  pure (newPostgresStore pool, createUser)

emptyUserStore :: Pool Connection -> IO UserStore
emptyUserStore pool = newPostgresUserStore pool <$ wipe pool

-- | "<$" runs the action on the right, then returns the value on the left.
wipe :: Pool Connection -> IO ()
wipe pool = do
  _ <-
    withResource pool $ \conn ->
      execute_ conn "TRUNCATE accounts, transfers, entries, idempotency_keys, sessions, users RESTART IDENTITY CASCADE"
  pure ()
