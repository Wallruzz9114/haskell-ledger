-- | The pure heart of the ledger. No IO, no database, no HTTP: just data in,
-- data out. Everything that matters about correctness lives here, which is
-- what makes it easy to test with properties.
--
-- "Pure" means every function here only looks at its arguments and returns a
-- result. It can't read files, print, or change anything. Call it twice with
-- the same input and you always get the same output. That's what lets the
-- tests (Step 7) throw hundreds of random scenarios at it.
--
-- Note the export list: "Ledger" is exported WITHOUT "(..)". Other modules
-- can hold and pass around a Ledger, but can't look inside it or build one
-- directly. They have to go through the functions below, the same smart
-- constructor idea as Amount in Ledger.Money.
module Ledger.Core
  ( Ledger
  , emptyLedger
  , openAccount
  , lookupAccount
  , listAccounts
  , balanceOf
  , entriesFor
  , checkTransfer
  , applyTransfer
  , totalOfAllBalances
  , allBalances
  ) where

-- foldl' is a strict left fold: "reduce" in TypeScript (more on it below).
import Data.List (foldl')
-- Two imports from the same module, a common Haskell idiom:
--   the first brings in just the TYPE name "Map", unqualified, for signatures;
--   the second brings in everything else, but only as "Map.something".
-- "qualified ... as Map" means we must write Map.insert, Map.lookup, etc.
-- That avoids clashes: lists also have functions called lookup and filter.
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Ledger.Money (Cents (..), unAmount)
-- No list in parentheses: import everything Ledger.Types exports.
import Ledger.Types

-- | The whole state of the ledger, as one immutable value.
--
-- "Map k v" is an immutable dictionary from keys k to values v, like a
-- TypeScript Map you can't mutate: Map.insert returns a NEW map and leaves
-- the old one untouched.
data Ledger = Ledger
  { ledgerAccounts :: Map AccountId Account
  , ledgerBalances :: Map AccountId Cents
  , ledgerEntries :: Map AccountId [Entry] -- newest first
  -- "[Entry]" is the type "list of Entry", like Entry[] in TypeScript.
  , ledgerNextTransferId :: Integer
  }

-- | A ledger with no accounts, where the first transfer will get ID 1.
--
-- Here we build a record by position instead of by field name: the four
-- arguments fill the four fields in order.
emptyLedger :: Ledger
emptyLedger = Ledger Map.empty Map.empty Map.empty 1

-- | Open a new account, or fail if the ID is taken.
--
-- Read the type signature left to right: takes an id, a name, a kind, an
-- owner (Nothing for system accounts) and the current ledger, and returns EITHER an error (Left) OR a pair of the new
-- account and the new ledger (Right).
--
-- "(Account, Ledger)" is a tuple: a fixed-size group of values, like
-- [Account, Ledger] as a TypeScript tuple type.
--
-- Note the ledger comes LAST. That's a Haskell convention: the "thing being
-- worked on" goes last, so it's easy to chain calls or fill in the other
-- arguments first.
openAccount
  :: AccountId -> Text -> AccountKind -> Maybe Username -> Ledger -> Either OpenAccountError (Account, Ledger)
openAccount aid name kind owner ledger
  -- Guards again (see mkAmount in Ledger.Money): the first True line wins.
  | Map.member aid (ledgerAccounts ledger) = Left (AccountAlreadyExists aid)
  | otherwise =
      -- "let ... in ..." names intermediate values, then uses them.
      let account = Account aid name kind owner
       in Right
            ( account
            , -- Record update syntax: a COPY of ledger with three fields
              -- changed. The original "ledger" still exists, unchanged.
              -- In TypeScript: { ...ledger, ledgerAccounts: ..., ... }
              ledger
                { ledgerAccounts = Map.insert aid account (ledgerAccounts ledger)
                , ledgerBalances = Map.insert aid 0 (ledgerBalances ledger)
                , ledgerEntries = Map.insert aid [] (ledgerEntries ledger)
                }
            )

-- | Find an account by ID. Maybe because it might not exist.
--
-- This is written "point-free": there's no ledger argument on the left of
-- "=". "Map.lookup aid . ledgerAccounts" is a function that first gets the
-- accounts map out of a ledger, then looks up aid in it. It means the same
-- as:  lookupAccount aid ledger = Map.lookup aid (ledgerAccounts ledger)
lookupAccount :: AccountId -> Ledger -> Maybe Account
lookupAccount aid = Map.lookup aid . ledgerAccounts

-- | Every account paired with its balance.
--
-- This is a list comprehension, like Python's:
--   [ result | pattern <- source ]
-- "for each (aid, a) in the accounts map, produce (a, its balance)".
-- Map.toList turns the map into a list of (key, value) pairs.
-- Map.findWithDefault 0 returns 0 if the key isn't found.
listAccounts :: Ledger -> [(Account, Cents)]
listAccounts ledger =
  [ (a, Map.findWithDefault 0 aid (ledgerBalances ledger))
  | (aid, a) <- Map.toList (ledgerAccounts ledger)
  ]

-- | An account's balance, or Nothing if there's no such account.
balanceOf :: AccountId -> Ledger -> Maybe Cents
balanceOf aid = Map.lookup aid . ledgerBalances

-- | An account's entries, newest first, or Nothing if there's no such account.
entriesFor :: AccountId -> Ledger -> Maybe [Entry]
entriesFor aid = Map.lookup aid . ledgerEntries

-- | Every balance, keyed by account. Used by the tests.
--
-- Point-free again: allBalances IS the field accessor ledgerBalances,
-- under a name that can be exported without exposing the Ledger internals.
allBalances :: Ledger -> Map AccountId Cents
allBalances = ledgerBalances

-- | With double-entry bookkeeping this is always zero. It's the invariant the
-- property tests check after every random sequence of transfers.
--
-- Read the pipeline right to left (each "." feeds its result leftwards):
--   ledgerBalances   get the balances map
--   Map.elems        take just the values, as a list of Cents
--   foldl' (+) 0     add them all up, starting from 0
-- In TypeScript: [...ledger.balances.values()].reduce((a, b) => a + b, 0)
-- "(+)" is the + operator used as an ordinary function.
totalOfAllBalances :: Ledger -> Cents
totalOfAllBalances = foldl' (+) 0 . Map.elems . ledgerBalances

-- | The transfer rules, on their own: given the request, the two accounts
-- (Nothing if an account doesn't exist) and the sender's current balance,
-- is this transfer allowed?
--
-- Both stores call this: applyTransfer below (in-memory) and
-- Ledger.Store.Postgres (which loads the two accounts from the database).
-- So the rules are written exactly once, and the property tests that
-- exercise applyTransfer also cover the Postgres store's decisions.
--
-- This "do" block runs in Either. Each line either succeeds and moves on, or
-- produces a Left, which STOPS the block and becomes the function's result.
-- It works like a series of guard clauses:
--   if (!from) return error; if (!to) return error; if (same) return error...
-- except the type makes it impossible to forget to return, or to skip a check.
checkTransfer :: TransferRequest -> Maybe Account -> Maybe Account -> Cents -> Either TransferError ()
checkTransfer req mFrom mTo fromBalance = do
  -- "x <- action" runs the action and, if it's a Right, names the value
  -- inside x. If it's a Left, the whole do block stops here with that error.
  fromAcct <- found (reqFrom req) mFrom
  -- "_ <-" means "run the check, but I don't need the value".
  _ <- found (reqTo req) mTo
  -- A check that returns no value: Left stops everything, Right () carries
  -- on. "()" is the "unit" value, Haskell's equivalent of void.
  if reqFrom req == reqTo req then Left SameAccount else Right ()
  -- "let" inside a do block just names values. It can't fail.
  let amount = unAmount (reqAmount req)
  -- The overdraft rule: customers can't go below zero; External can.
  -- The last line of the block is the result: Left (stop) or Right ().
  if accountKind fromAcct == Customer && fromBalance < amount
    then Left (InsufficientFunds {available = fromBalance, requested = amount})
    else Right ()
  where
    -- Turns "Maybe Account" into "Either TransferError Account", so a
    -- missing account becomes an error the do block understands.
    -- "maybe default f m": if m is Nothing, use default; if Just x, use f x.
    found aid = maybe (Left (UnknownAccount aid)) Right

-- | Validate and apply a transfer. Either the whole thing happens (two
-- entries, both balances updated) or nothing does.
applyTransfer :: TransferRequest -> Ledger -> Either TransferError (Transfer, Ledger)
applyTransfer req ledger = do
  -- Run the rules. A Left here stops the whole do block with that error.
  checkTransfer
    req
    (lookupAccount (reqFrom req) ledger)
    (lookupAccount (reqTo req) ledger)
    (Map.findWithDefault 0 (reqFrom req) (ledgerBalances ledger))
  -- Every check passed. Now build the results. Still nothing is modified:
  -- ledger' (read "ledger prime") is a brand-new ledger value.
  let amount = unAmount (reqAmount req)
      tid = TransferId (ledgerNextTransferId ledger)
      transfer = Transfer tid (reqFrom req) (reqTo req) amount (reqMemo req)
      -- The two sides of double-entry: they always sum to zero.
      debit = Entry tid (reqFrom req) (negate amount)
      credit = Entry tid (reqTo req) amount
      ledger' =
        ledger
          { -- "f $ x" means "f (x)": it saves a pair of parentheses.
            -- Map.adjust f key applies f to one key's value.
            -- So: subtract from the sender, THEN add to the receiver.
            -- "(+ amount)" and "(subtract amount)" are functions with one
            -- argument already filled in ("sections"): x -> x + amount.
            ledgerBalances =
              Map.adjust (+ amount) (reqTo req) $
                Map.adjust (subtract amount) (reqFrom req) (ledgerBalances ledger)
          , -- "(credit :)" puts credit on the FRONT of a list, which is why
            -- entries are stored newest first (adding to the front is cheap).
            ledgerEntries =
              Map.adjust (credit :) (reqTo req) $
                Map.adjust (debit :) (reqFrom req) (ledgerEntries ledger)
          , ledgerNextTransferId = ledgerNextTransferId ledger + 1
          }
  -- "pure" wraps the final result in Right. It's the success case.
  pure (transfer, ledger')
