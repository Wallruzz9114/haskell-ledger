{-# LANGUAGE OverloadedStrings #-}

-- | The program's entry point. A Haskell program starts at "main" in the
-- module called Main, like the function node runs first in index.js.
--
-- This file is deliberately thin: it wires things together (pick a store,
-- seed data, read the port, start the server). All the real logic lives in
-- the library under src/.
module Main (main) where

-- void runs an action and throws its result away.
import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as BS
import Data.Maybe (fromMaybe)
import Ledger.App (Env (..), app, externalAccountId)
import Ledger.Db (newDbPool, runMigrations)
import Ledger.Money (mkAmount)
import Ledger.Store
import Ledger.Store.Postgres (newPostgresStore)
import Ledger.Types
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import System.IO (BufferMode (..), hSetBuffering, stdout)
import Text.Read (readMaybe)

-- | "main :: IO ()" means: an action that talks to the outside world and
-- produces nothing useful ("()" is like void). Every program's main has
-- this type.
main :: IO ()
main = do
  -- Print each log line as soon as it's written. By default Haskell holds
  -- output back in a buffer when stdout isn't a terminal (a log file, a
  -- Docker container), so lines could appear late or not at all.
  hSetBuffering stdout LineBuffering
  store <- storeFromEnvironment
  -- "void" throws away the result (the new account, or AccountAlreadyExists
  -- when a Postgres database already has it from an earlier run).
  void (storeOpenAccount store externalAccountId "External (outside the ledger)" External)
  seedDemoData store
  -- Read the PORT environment variable, falling back to 8080. Right to left:
  --   lookupEnv "PORT"    -> Maybe String (Nothing if PORT isn't set)
  --   (>>= readMaybe)     -> try to parse it as a number; Nothing on failure
  --   fromMaybe 8080      -> Nothing becomes 8080; Just p becomes p
  -- "<$>" applies that to the result of the IO action lookupEnv.
  port <- fromMaybe 8080 . (>>= readMaybe) <$> lookupEnv "PORT"
  application <- app (Env store)
  -- "<>" joins strings; show turns the port number into a String.
  putStrLn ("Ledger API listening on http://localhost:" <> show port)
  -- Start the Warp web server. This runs until you stop it with Ctrl+C.
  run port application

-- | Use Postgres when DATABASE_URL is set, otherwise keep everything in
-- memory. Both give back the same LedgerStore type, so nothing after this
-- function knows which one it got.
storeFromEnvironment :: IO LedgerStore
storeFromEnvironment = do
  mUrl <- lookupEnv "DATABASE_URL"
  case mUrl of
    Nothing -> do
      putStrLn "DATABASE_URL not set: using the in-memory store (data is lost on restart)"
      newInMemoryStore
    Just url -> do
      -- BS.pack turns the String into the bytes postgresql-simple expects.
      pool <- newDbPool (BS.pack url)
      applied <- runMigrations pool
      forM_ applied $ \name -> putStrLn ("Applied migration " <> name)
      putStrLn "Using the Postgres store"
      pure (newPostgresStore pool)

-- | Demo accounts and transfers so the UI and the database have something to
-- show on first run.
--
-- Safe to run on every startup, even against a database that already has
-- the data: opening an existing account just returns AccountAlreadyExists,
-- and each transfer carries its own idempotency key, so a restart replays
-- the remembered result instead of moving the money again. The seed uses
-- the ledger's own idempotency feature to make itself repeatable.
seedDemoData :: LedgerStore -> IO ()
seedDemoData store = do
  void (storeOpenAccount store acmeOps "Acme Operating" Customer)
  void (storeOpenAccount store acmePayroll "Acme Payroll" Customer)
  seedTransfer "seed:deposit" externalAccountId acmeOps 2500000 "Seed deposit"
  seedTransfer "seed:payroll-august" acmeOps acmePayroll 400000 "August payroll"
  where
    acmeOps = AccountId "acme-ops"
    acmePayroll = AccountId "acme-payroll"
    -- mkAmount returns a Maybe, so even with hard-coded numbers we must
    -- handle Nothing. That's the smart constructor doing its job.
    seedTransfer key from to cents memo = case mkAmount cents of
      Just amount -> void (storeTransfer store (Just (IdempotencyKey key)) (TransferRequest from to amount memo))
      Nothing -> pure ()
