-- | The API server's entry point. A Haskell program starts at "main" in the
-- module called Main, like the function node runs first in index.js.
--
-- This file is deliberately thin: it wires things together (pick a store,
-- read the port, start the server). All the real logic lives in the library
-- under src/.
module Main (main) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as BS
import Data.Maybe (fromMaybe)
import Ledger.App (Env (..), app)
import Ledger.Db (newDbPool, runMigrations)
import Ledger.Seed (ensureSystemAccounts, seedDemoData)
import Ledger.Store
import Ledger.Store.Postgres (newPostgresStore)
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
      putStrLn "DATABASE_URL not set: using the in-memory store with demo data (lost on restart)"
      store <- newInMemoryStore
      -- An in-memory ledger starts empty every time, so fill it with demo
      -- data straight away; otherwise there would be nothing to look at.
      seedDemoData store
      pure store
    Just url -> do
      -- BS.pack turns the String into the bytes postgresql-simple expects.
      pool <- newDbPool (BS.pack url)
      applied <- runMigrations pool
      forM_ applied $ \name -> putStrLn ("Applied migration " <> name)
      let store = newPostgresStore pool
      -- A real database only gets the accounts the ledger needs to work.
      -- Demo data is added separately, on request: cabal run ledger-seed.
      ensureSystemAccounts store
      putStrLn "Using the Postgres store (add demo data with: cabal run ledger-seed)"
      pure store
