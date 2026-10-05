{-# LANGUAGE OverloadedStrings #-}

-- | Tests for Ledger.Reports: the dashboard numbers and transaction paging.
-- Worked examples first, then properties over random entries.
module Ledger.ReportsSpec (spec) where

import Data.Either (isLeft)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, UTCTime (..), addDays, fromGregorian)
import Ledger.Money (Cents (..))
import Ledger.Reports
import Ledger.Types
import Test.Hspec
import Test.QuickCheck

ops, payroll, globex, external :: AccountId
ops = AccountId "acme-ops"
payroll = AccountId "acme-payroll"
globex = AccountId "globex-ops"
external = AccountId "external"

-- | alice's two accounts.
mine :: Set.Set AccountId
mine = Set.fromList [ops, payroll]

names :: Map.Map AccountId Text
names = Map.fromList [(ops, "Acme Operating"), (payroll, "Acme Payroll"), (globex, "Globex Operating"), (external, "External")]

-- | An entry on a given day at noon.
entryOn :: Integer -> AccountId -> Integer -> AccountId -> Text -> Day -> Entry
entryOn tid account cents other memo day =
  Entry (TransferId tid) account (Cents cents) other memo (UTCTime day 43200)

sep :: Int -> Day
sep = fromGregorian 2026 9

-- | A small September for alice:
--   Sep 2  +1000 from external (a client pays)
--   Sep 10  -300 to globex (an invoice)
--   Sep 20  -200 ops -> payroll (her own money, moving between her accounts)
september :: [Entry]
september =
  [ entryOn 1 ops 1000 external "Client payment" (sep 2)
  , entryOn 2 ops (-300) globex "Invoice" (sep 10)
  , entryOn 3 ops (-200) payroll "Payroll funding" (sep 20)
  , entryOn 3 payroll 200 ops "Payroll funding" (sep 20)
  ]

-- | Her total now: 1000 - 300 (the internal move nets to zero).
septemberTotal :: Cents
septemberTotal = 700

spec :: Spec
spec = do
  describe "dashboard" $ do
    let report = dashboard mine septemberTotal september (sep 30) 30 (sep 15)

    it "counts only money that crossed the boundary of her accounts" $ do
      dashMoneyIn report `shouldBe` 1000
      -- The 200 moved from ops to payroll isn't money out: it never left.
      dashMoneyOut report `shouldBe` 300

    it "lists who paid her and who she paid" $ do
      dashTopSources report `shouldBe` [PartyTotal external 1000]
      dashTopSpending report `shouldBe` [PartyTotal globex 300]

    it "has one balance per day, ending at today's total" $ do
      length (dashSeries report) `shouldBe` 30
      map pointDay (dashSeries report) `shouldBe` [sep 1 .. sep 30]
      -- Before anything happened: 0. After the client payment: 1000.
      -- After the invoice: 700, and the internal move doesn't change it.
      [pointBalance p | p <- dashSeries report, pointDay p `elem` [sep 1, sep 2, sep 10, sep 20, sep 30]]
        `shouldBe` [0, 1000, 700, 700, 700]

    it "only counts the chosen month's money in and out" $ do
      let august = dashboard mine septemberTotal september (sep 30) 30 (fromGregorian 2026 8 15)
      (dashMoneyIn august, dashMoneyOut august) `shouldBe` (0, 0)

    it "ends the balance chart at the current total, whatever the entries" $
      property $ \(Entries es) days ->
        let current = sum (map entryAmount es)
            report' = dashboard mine current es today (1 + getSmall (getNonNegative days)) today
         in (pointBalance <$> lastMaybe (dashSeries report')) == Just current
              && length (dashSeries report') == fromIntegral (1 + getSmall (getNonNegative days))

  describe "transactionsPage" $ do
    let everything = TransactionQuery Nothing "" Nothing 100

    it "lists entries newest first" $
      fmap (map entryMemo . fst) (transactionsPage everything names september)
        `shouldBe` Right ["Payroll funding", "Payroll funding", "Invoice", "Client payment"]

    it "searches memos and account names, ignoring case" $ do
      let search q = fmap (map entryMemo . fst) (transactionsPage everything {querySearch = q} names september)
      search "invoice" `shouldBe` Right ["Invoice"]
      -- "globex" isn't in any memo; it's the counterparty's display name.
      search "GLOBEX operating" `shouldBe` Right ["Invoice"]

    it "filters to one account" $
      fmap (map entryAccount . fst) (transactionsPage everything {queryAccount = Just payroll} names september)
        `shouldBe` Right [payroll]

    it "refuses a cursor that matches nothing" $
      transactionsPage everything {queryBefore = Just "999:nowhere"} names september `shouldSatisfy` isLeft

    it "pages through everything exactly once, in order, whatever the page size" $
      property $ \(Entries es) (Positive size) ->
        let pages = allPages (min 20 size) es
         in pages == Right (sortOn (\e -> Down (entryCreatedAt e, entryTransfer e, entryAccount e)) es)
  where
    today = sep 30
    lastMaybe [] = Nothing
    lastMaybe xs = Just (last xs)

-- | Follow nextCursor from the first page to the last, collecting entries.
allPages :: Int -> [Entry] -> Either Text [Entry]
allPages size es = go Nothing
  where
    go cursor = do
      (page, next) <- transactionsPage (TransactionQuery Nothing "" cursor size) Map.empty es
      rest <- maybe (Right []) (go . Just) next
      pure (page ++ rest)

-- | Random entries on alice's accounts over the last 60 days, each with its
-- own transfer id (so every entry has a distinct cursor).
newtype Entries = Entries [Entry]
  deriving (Show)

instance Arbitrary Entries where
  arbitrary = do
    n <- chooseInt (0, 40)
    Entries <$> mapM randomEntry [1 .. fromIntegral n]
    where
      randomEntry tid = do
        account <- elements [ops, payroll]
        other <- elements [globex, external, ops, payroll]
        cents <- chooseInteger (-5000, 5000)
        daysAgo <- chooseInteger (0, 59)
        seconds <- chooseInteger (0, 86399)
        pure (Entry (TransferId tid) account (Cents cents) other (T.pack ("memo " <> show tid)) (UTCTime (addDays (negate daysAgo) (sep 30)) (fromIntegral seconds)))
