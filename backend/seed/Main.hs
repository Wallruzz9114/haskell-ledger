{-# LANGUAGE OverloadedStrings #-}

-- | The "ledger-seed" command: fill the database at DATABASE_URL with demo
-- data, then print every account's balance.
--
--   DATABASE_URL=postgresql://USER:PASSWORD@HOST:PORT/DATABASE cabal run ledger-seed
--
-- Safe to run again: every seed transfer has an idempotency key, so a second
-- run changes nothing (see Ledger.Seed).
module Main (main) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as BS
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Ledger.Db (newDbPool, runMigrations)
import Ledger.Money (formatCents)
import Ledger.Seed (demoTransfers, seedDemoData)
import Ledger.Store
import Ledger.Store.Postgres (newPostgresStore)
import Ledger.Types
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  mUrl <- lookupEnv "DATABASE_URL"
  case mUrl of
    -- Refuse to guess which database to write to.
    Nothing -> do
      -- hPutStrLn stderr: print to the error stream instead of normal output.
      hPutStrLn stderr "DATABASE_URL is not set. Point it at the database to seed:"
      hPutStrLn stderr "  DATABASE_URL=postgresql://USER:PASSWORD@HOST:PORT/DATABASE cabal run ledger-seed"
      hPutStrLn stderr "The README has the value for the docker compose database."
      exitFailure
    Just url -> do
      pool <- newDbPool (BS.pack url)
      applied <- runMigrations pool
      forM_ applied $ \name -> putStrLn ("Applied migration " <> name)
      let store = newPostgresStore pool
      seedDemoData store
      putStrLn ("Seeded " <> show (length demoTransfers) <> " demo transfers (already-seeded ones are skipped).")
      putStrLn ""
      accounts <- storeListAccounts store
      forM_ accounts $ \(account, balance) -> do
        let AccountId aid = accountId account
        -- justifyLeft / justifyRight pad the text into neat columns.
        TIO.putStrLn (T.justifyLeft 16 ' ' aid <> T.justifyRight 16 ' ' (formatCents balance))
