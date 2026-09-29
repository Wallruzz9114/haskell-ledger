{-# LANGUAGE OverloadedStrings #-}

-- | The program's entry point. A Haskell program starts at "main" in the
-- module called Main, like the function node runs first in index.js.
--
-- This file is deliberately thin: it wires things together (create the
-- store, seed data, read the port, start the server). All the real logic
-- lives in the library under src/.
module Main (main) where

import Ledger.App (Env (..), app, externalAccountId)
import Ledger.Money (mkAmount)
import Ledger.Store
import Ledger.Types
import Network.Wai.Handler.Warp (run)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | "main :: IO ()" means: an action that talks to the outside world and
-- produces nothing useful ("()" is like void). Every program's main has
-- this type.
main :: IO ()
main = do
  store <- newInMemoryStore
  -- "_ <-" throws away the result (the new account, or an error we don't
  -- expect on a fresh store).
  _ <- storeOpenAccount store externalAccountId "External (outside the ledger)" External
  seedDemoData store
  -- Read the PORT environment variable, falling back to 8080. Right to left:
  --   lookupEnv "PORT"    -> Maybe String (Nothing if PORT isn't set)
  --   (>>= readMaybe)     -> try to parse it as a number; Nothing on failure
  --   maybe 8080 id       -> Nothing becomes 8080; Just p becomes p
  -- "<$>" applies that to the result of the IO action lookupEnv.
  port <- maybe 8080 id . (>>= readMaybe) <$> lookupEnv "PORT"
  application <- app (Env store)
  -- "<>" joins strings; show turns the port number into a String.
  putStrLn ("Ledger API listening on http://localhost:" <> show port)
  -- Start the Warp web server. This runs until you stop it with Ctrl+C.
  run port application

-- | Two funded demo accounts so the UI has something to show on first load.
seedDemoData :: LedgerStore -> IO ()
seedDemoData store = do
  _ <- storeOpenAccount store (AccountId "acme-ops") "Acme Operating" Customer
  _ <- storeOpenAccount store (AccountId "acme-payroll") "Acme Payroll" Customer
  -- mkAmount returns a Maybe, so even with a hard-coded number we must
  -- handle Nothing. That's the smart constructor doing its job.
  case mkAmount 2500000 of
    -- "() <$ action" runs the action and replaces its result with (), since
    -- this function returns IO () and we don't need the transfer.
    Just amount -> () <$ storeTransfer store Nothing (TransferRequest externalAccountId (AccountId "acme-ops") amount "Seed deposit")
    Nothing -> pure ()
