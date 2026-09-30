{-# LANGUAGE OverloadedStrings #-}

-- | The numbers behind the dashboard and the transactions page.
--
-- Pure, like Ledger.Core: every function takes plain values (entries,
-- account ids, a date) and returns plain values. No database, no clock, no
-- HTTP. The HTTP layer fetches the entries, calls these, and turns the
-- results into JSON. That keeps the arithmetic easy to test (see
-- test/Ledger/ReportsSpec.hs), including with random data.
module Ledger.Reports
  ( -- * Dashboard
    Dashboard (..)
  , BalancePoint (..)
  , PartyTotal (..)
  , dashboard

    -- * Transactions
  , TransactionQuery (..)
  , transactionsPage
  , entryCursor
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime (..), addDays, toGregorian)
import Ledger.Money (Cents (..))
import Ledger.Types

-- Dashboard ---------------------------------------------------------------------

-- | Everything the dashboard shows, for one set of accounts ("mine").
data Dashboard = Dashboard
  { dashTotal :: Cents
  -- ^ The total balance of those accounts right now.
  , dashSeries :: [BalancePoint]
  -- ^ The total at the end of each day, oldest first, ending today.
  , dashMoneyIn :: Cents
  -- ^ Money that arrived from OTHER accounts during the month.
  , dashMoneyOut :: Cents
  -- ^ Money that left for other accounts during the month, as a positive
  -- number.
  , dashTopSources :: [PartyTotal]
  -- ^ Who sent the most money in, biggest first (at most 5).
  , dashTopSpending :: [PartyTotal]
  -- ^ Who received the most money, biggest first (at most 5).
  }
  deriving (Eq, Show)

data BalancePoint = BalancePoint
  { pointDay :: Day
  , pointBalance :: Cents
  }
  deriving (Eq, Show)

-- | A counterparty and a total, e.g. (globex-ops, 3,200.00).
data PartyTotal = PartyTotal
  { partyAccount :: AccountId
  , partyTotal :: Cents
  }
  deriving (Eq, Show)

-- | Build the dashboard.
--
-- Arguments: the accounts that count as "mine", their current total
-- balance, every entry on those accounts, today's date, how many days the
-- chart covers, and which month the money-in/out figures are for (any day
-- in that month).
--
-- Transfers between two of "my" accounts (alice moving money from
-- operating to payroll) are left out of money in/out: the money never
-- left. They still show in the balance series of course (they net to zero).
dashboard :: Set AccountId -> Cents -> [Entry] -> Day -> Integer -> Day -> Dashboard
dashboard mine total entries today days monthOf =
  Dashboard
    { dashTotal = total
    , dashSeries = [BalancePoint d (balanceAtEndOf d) | d <- [addDays (1 - days) today .. today]]
    , dashMoneyIn = sum (map entryAmount incoming)
    , dashMoneyOut = negate (sum (map entryAmount outgoing))
    , dashTopSources = topFive incoming
    , dashTopSpending = map (\p -> p {partyTotal = negate (partyTotal p)}) (topFive outgoing)
    }
  where
    -- Walk backwards from today's total: the balance at the end of day d is
    -- the total now, minus everything that happened after d.
    balanceAtEndOf d = total - sum [entryAmount e | e <- entries, dayOf e > d]

    -- This month's entries with someone outside "my" accounts.
    external = [e | e <- entries, sameMonth (dayOf e) monthOf, not (Set.member (entryCounterparty e) mine)]
    incoming = filter ((> 0) . entryAmount) external
    outgoing = filter ((< 0) . entryAmount) external

    -- Add up the amounts per counterparty, then keep the five largest
    -- (largest money in, or most negative money out).
    topFive es =
      take 5
        . sortOn (Down . abs . partyTotal)
        . map (uncurry PartyTotal)
        . Map.toList
        $ Map.fromListWith (+) [(entryCounterparty e, entryAmount e) | e <- es]

dayOf :: Entry -> Day
dayOf = utctDay . entryCreatedAt

-- | Same calendar month (and year)?
sameMonth :: Day -> Day -> Bool
sameMonth a b = yearMonth a == yearMonth b
  where
    -- toGregorian gives (year, month, day); keep the first two.
    yearMonth d = let (y, m, _) = toGregorian d in (y, m)

-- Transactions --------------------------------------------------------------------

-- | What the transactions page asks for.
data TransactionQuery = TransactionQuery
  { queryAccount :: Maybe AccountId
  -- ^ Only this account's entries (Nothing: all of "my" accounts).
  , querySearch :: Text
  -- ^ Words to look for in the memo, account names and counterparty names
  -- (empty: no search).
  , queryBefore :: Maybe Text
  -- ^ The cursor from the previous page: continue after this entry.
  , queryLimit :: Int
  }

-- | A stable name for an entry, used as the paging cursor: "40:acme-ops".
-- A transfer has two entries (one per side), so the account is part of it.
entryCursor :: Entry -> Text
entryCursor e = T.pack (show tid) <> ":" <> aid
  where
    TransferId tid = entryTransfer e
    AccountId aid = entryAccount e

-- | One page of entries, newest first, and the cursor for the next page
-- (Nothing when this is the last page). Left means the cursor didn't match
-- any entry.
--
-- The names map (account id -> display name) is what the search looks in,
-- so people can search "globex" and find "Globex Operating".
transactionsPage :: TransactionQuery -> Map.Map AccountId Text -> [Entry] -> Either Text ([Entry], Maybe Text)
transactionsPage query names entries = do
  afterCursor <- case queryBefore query of
    Nothing -> Right matching
    Just cursor -> case break ((== cursor) . entryCursor) matching of
      (_, _ : rest) -> Right rest
      (_, []) -> Left "That page cursor doesn't match any transaction. Start again from the first page."
  let (page, rest) = splitAt (queryLimit query) afterCursor
      next = if null rest then Nothing else entryCursor <$> lastMaybe page
  pure (page, next)
  where
    -- Newest first: by time, then transfer number, then account, so the
    -- order is the same on every request (which paging relies on).
    matching =
      sortOn (\e -> Down (entryCreatedAt e, entryTransfer e, entryAccount e)) $
        filter matchesAccount (filter matchesSearch entries)

    matchesAccount e = maybe True (== entryAccount e) (queryAccount query)

    -- Every word typed must appear somewhere (case doesn't matter).
    searchWords = T.words (T.toLower (querySearch query))
    matchesSearch e = all (`T.isInfixOf` haystack e) searchWords
    haystack e =
      T.toLower . T.unwords $
        [ entryMemo e
        , nameOf (entryAccount e)
        , nameOf (entryCounterparty e)
        , let AccountId a = entryCounterparty e in a
        ]
    nameOf aid = Map.findWithDefault "" aid names

    lastMaybe [] = Nothing
    lastMaybe xs = Just (last xs)
