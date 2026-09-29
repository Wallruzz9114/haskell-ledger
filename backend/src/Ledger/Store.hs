-- | The storage boundary, written as a record of functions. Handlers depend
-- on this record, not on a concrete database, so the in-memory store (here)
-- and the Postgres store (Ledger.Store.Postgres) are interchangeable.
--
-- This is the first file with IO: the ledger now lives somewhere and changes
-- over time. Ledger.Core stays pure; this file wraps it in a place to keep
-- the current ledger and a safe way to update it.
module Ledger.Store
  ( LedgerStore (..)
  , newInMemoryStore
  ) where

-- STM = Software Transactional Memory: TVar, atomically, readTVar, etc.
-- No import list means "import everything this module exports".
import Control.Concurrent.STM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Ledger.Core
import Ledger.Money (Cents)
import Ledger.Types

-- | Everything the rest of the app can do with stored data.
--
-- It's a record whose fields are FUNCTIONS: an interface written as plain
-- data. In TypeScript:
--   interface LedgerStore {
--     openAccount(id: AccountId, name: string, kind: AccountKind):
--       Promise<Either<OpenAccountError, Account>>
--     ...
--   }
-- "IO x" means "an action that, when run, talks to the outside world and
-- produces an x". It's roughly like Promise<x>: a description of work, not
-- the work itself.
--
-- Anything that needs storage takes a LedgerStore. There are two
-- implementations: the in-memory one below, and Ledger.Store.Postgres.
-- Main picks one at startup; no caller knows or cares which it got. This is
-- dependency injection with no framework.
data LedgerStore = LedgerStore
  { storeOpenAccount :: AccountId -> Text -> AccountKind -> IO (Either OpenAccountError Account)
  , storeGetAccount :: AccountId -> IO (Maybe (Account, Cents))
  , storeListAccounts :: IO [(Account, Cents)]
  , storeEntries :: AccountId -> IO (Maybe [Entry])
  , -- "Maybe IdempotencyKey": the key is optional, the client may not send one.
    storeTransfer :: Maybe IdempotencyKey -> TransferRequest -> IO (Either TransferError Transfer)
  }

-- | Remembered outcome of a request made with an idempotency key. We keep the
-- original request so a key reused with a different body is rejected, not
-- silently answered with the wrong result.
--
-- A constructor with two unnamed fields: the request, and what happened.
-- Not exported: nothing outside this file needs to know about it.
data Remembered = Remembered TransferRequest (Either TransferError Transfer)

-- | An in-memory store backed by STM. Every transfer, including the
-- idempotency check, runs in one atomic transaction, so concurrent requests
-- can never overdraw an account or apply the same key twice.
--
-- The type "IO LedgerStore" means: an action that creates a store. It's IO
-- because creating the store allocates mutable variables.
newInMemoryStore :: IO LedgerStore
-- This "do" block runs in IO: each line is an action, run in order.
newInMemoryStore = do
  -- A TVar is a mutable box that can only be changed inside "atomically".
  -- "x <- action" runs an IO action and names its result.
  -- newTVarIO creates a TVar holding a starting value.
  ledgerVar <- newTVarIO emptyLedger
  -- "(Map.empty :: Map IdempotencyKey Remembered)" tells the compiler which
  -- kind of empty map we mean, since it can't work that out on its own.
  keysVar <- newTVarIO (Map.empty :: Map IdempotencyKey Remembered)
  -- "pure" returns the finished store as the result of the action.
  -- Each field below is a lambda that closes over ledgerVar and keysVar,
  -- the same way a JavaScript closure captures variables.
  pure
    LedgerStore
      { -- "\aid name kind -> ..." is a lambda: (aid, name, kind) => ...
        -- "atomically $ do ..." runs the whole block as ONE transaction:
        -- other threads either see all of it or none of it.
        storeOpenAccount = \aid name kind -> atomically $ do
          ledger <- readTVar ledgerVar
          -- "case" is pattern matching on a value: a switch that can also
          -- unpack the data inside each alternative.
          case openAccount aid name kind ledger of
            Left err -> pure (Left err)
            Right (account, ledger') -> do
              writeTVar ledgerVar ledger'
              pure (Right account)
      , storeGetAccount = \aid -> do
          -- readTVarIO reads a TVar outside a transaction: fine for a single
          -- read, since one read is always consistent on its own.
          ledger <- readTVarIO ledgerVar
          -- "(,) <$> a <*> b" combines two Maybes into a Maybe pair:
          --   Just x, Just y       -> Just (x, y)
          --   anything with Nothing -> Nothing
          -- "(,)" is the tuple-building function: (,) x y == (x, y).
          -- "<$>" and "<*>" apply a function to values inside a Maybe.
          pure ((,) <$> lookupAccount aid ledger <*> balanceOf aid ledger)
      , -- "<$>" is fmap: apply a function to the result of an action, like
        -- promise.then(listAccounts). Reads the ledger, then lists accounts.
        storeListAccounts = listAccounts <$> readTVarIO ledgerVar
      , storeEntries = \aid -> entriesFor aid <$> readTVarIO ledgerVar
      , storeTransfer = \mkey req -> atomically $ do
          -- Everything in this block is one transaction: the idempotency
          -- check, the balance check and the write. Two concurrent requests
          -- can't both see "1000 available" and both spend it: STM detects
          -- the conflict and re-runs one of them against the new state.
          keys <- readTVar keysVar
          -- ">>=" chains Maybe steps: if there's no key, the result is
          -- Nothing; otherwise look the key up in the map.
          -- "(`Map.lookup` keys)" is a section: \k -> Map.lookup k keys.
          case mkey >>= (`Map.lookup` keys) of
            -- Seen this key before: replay the original outcome if it's the
            -- same request, otherwise refuse.
            -- Guards work inside case alternatives too.
            Just (Remembered original result)
              | original == req -> pure result
              | otherwise -> pure (Left IdempotencyKeyReused)
            -- New key (or no key at all): actually run the transfer.
            Nothing -> do
              ledger <- readTVar ledgerVar
              let result = applyTransfer req ledger
                  -- "fst" takes the first element of a pair. "fst <$> result"
                  -- keeps the Transfer and drops the new ledger, but only if
                  -- result is a Right; a Left error passes through unchanged.
                  outcome = fst <$> result
              -- Only save the new ledger if the transfer succeeded.
              case result of
                Right (_, ledger') -> writeTVar ledgerVar ledger'
                Left _ -> pure ()
              -- Remember the outcome under the key (success OR failure),
              -- so a retry gets exactly the same answer.
              -- modifyTVar' applies a function to a TVar's contents.
              case mkey of
                Just key -> modifyTVar' keysVar (Map.insert key (Remembered req outcome))
                Nothing -> pure ()
              pure outcome
      }
