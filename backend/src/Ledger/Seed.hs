{-# LANGUAGE OverloadedStrings #-}

-- | Accounts the ledger always needs, and demo data to explore.
--
-- Demo data is only added when someone asks for it: by the "ledger-seed"
-- command (seed/Main.hs), or by the API when it runs with the in-memory
-- store. The API never adds demo data to a real database on its own.
--
-- Everything here goes through the normal LedgerStore functions, so the
-- seed obeys the same rules as any client, and works on either store.
module Ledger.Seed
  ( ensureSystemAccounts
  , seedDemoData
  , seedDemoDataAt
  , defaultDemoPassword
  , demoUsers
  , demoAccounts
  , demoTransfersUpTo
  , SeedTransfer (..)
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( Day
  , UTCTime (..)
  , addDays
  , dayOfWeek
  , fromGregorian
  , getCurrentTime
  , toGregorian
  )
import Ledger.Money (mkAmount)
import Ledger.Session (hashPassword)
import Ledger.Store
import Ledger.Types

-- | Accounts every ledger needs, demo or not. Today that's just "external",
-- where deposits come from. Safe to call on every startup: if it already
-- exists, opening it again just returns AccountAlreadyExists.
ensureSystemAccounts :: LedgerStore -> IO ()
ensureSystemAccounts store =
  void (storeOpenAccount store (AccountId "external") "External (outside the ledger)" External Nothing)

-- | One demo transfer. The key makes it repeatable (see seedDemoData).
data SeedTransfer = SeedTransfer
  { seedKey :: Text
  , seedFrom :: Text
  , seedTo :: Text
  , seedCents :: Integer
  , seedMemo :: Text
  , -- | When it happened, so the demo history reads like real activity.
    seedAt :: UTCTime
  }

-- | Add the demo users, accounts and transfers, dated up to now (see
-- demoTransfersUpTo).
seedDemoData :: Text -> LedgerStore -> UserStore -> IO ()
seedDemoData password store users = do
  now <- getCurrentTime
  seedDemoDataAt now password store users

-- | The same, as if the time were "now". Taking the time as an argument
-- (instead of reading the clock) lets the tests pick it.
--
-- Safe to run any number of times:
--
--   * opening an account that exists just returns AccountAlreadyExists;
--   * every transfer carries its own idempotency key, so a second run
--     replays the remembered result instead of moving the money again.
--     A run weeks later adds only the transfers dated since.
--
-- The seed uses the ledger's own idempotency feature to make itself
-- repeatable. If any transfer is REJECTED (say someone edits the list and
-- overdraws an account), it stops with an error instead of carrying on
-- with half the data.
seedDemoDataAt :: UTCTime -> Text -> LedgerStore -> UserStore -> IO ()
seedDemoDataAt now password store users = do
  ensureSystemAccounts store
  -- Users first, since accounts refer to their owners. An existing user is
  -- left alone (including their password).
  forM_ demoUsers $ \(name, role) -> do
    existing <- storeFindUser users (Username name)
    case existing of
      Just _ -> pure ()
      Nothing -> do
        hash <- hashPassword password
        void (storeCreateUser users (User (Username name) role) hash)
  forM_ demoAccounts $ \(aid, name, owner) ->
    storeOpenAccount store (AccountId aid) name Customer (Just (Username owner))
  -- A demo account that already existed from before accounts had owners
  -- has no owner: opening it again changed nothing, so give it its owner
  -- now. One owned by someone ELSE means the database has other data in
  -- it; stop rather than take it over.
  forM_ demoAccounts $ \(aid, _, owner) -> do
    found <- storeGetAccount store (AccountId aid)
    case accountOwner . fst <$> found of
      Just (Just current)
        | current == Username owner -> pure ()
        | otherwise ->
            fail
              ( "demo account " <> T.unpack aid <> " belongs to someone other than " <> T.unpack owner
                  <> ". Seed an empty database instead (docker compose down -v resets the local one)."
              )
      Just Nothing -> void (storeSetAccountOwner store (AccountId aid) (Username owner))
      Nothing -> fail ("demo account " <> T.unpack aid <> " couldn't be opened")
  forM_ (demoTransfersUpTo now) $ \t -> do
    amount <- maybe (fail ("seed amount must be positive: " <> T.unpack (seedKey t))) pure (mkAmount (seedCents t))
    let req = TransferRequest (AccountId (seedFrom t)) (AccountId (seedTo t)) amount (seedMemo t)
    -- storeTransferAt: recorded at the demo date, not at "now".
    result <- storeTransferAt store (seedAt t) (Just (IdempotencyKey (seedKey t))) req
    case result of
      Right _ -> pure ()
      Left err -> fail ("seed transfer " <> T.unpack (seedKey t) <> " was rejected: " <> show err)

-- | The password every demo user gets, unless DEMO_PASSWORD is set when
-- seeding. For local demos only: it's published in the README.
defaultDemoPassword :: Text
defaultDemoPassword = "ledger-demo-2026"

-- | (username, role) for every demo user: alice runs Acme, bob runs Globex,
-- and admin can see everything and make deposits.
demoUsers :: [(Text, Role)]
demoUsers =
  [ ("alice", RoleCustomer)
  , ("bob", RoleCustomer)
  , ("admin", RoleAdmin)
  ]

-- | (id, display name, owner) for every demo customer account.
demoAccounts :: [(Text, Text, Text)]
demoAccounts =
  [ ("acme-ops", "Acme Operating", "alice")
  , ("acme-payroll", "Acme Payroll", "alice")
  , ("acme-tax", "Acme Tax Reserve", "alice")
  , ("acme-savings", "Acme Savings", "alice")
  , ("globex-ops", "Globex Operating", "bob")
  , ("globex-payroll", "Globex Payroll", "bob")
  ]

-- | Every demo transfer dated at or before "now", oldest first: the three
-- whole months before this one, plus this month so far. So the demo always
-- looks current (this month's dashboard is never empty), and nothing is
-- dated in the future.
--
-- Each month's transfers depend only on WHICH month it is, never on when
-- the seed runs. That matters for the idempotency keys: "demo:2026-07:05"
-- must mean the same transfer every time, or a later run would be refused
-- with IdempotencyKeyReused. A run next week finds this week's keys done,
-- and adds only the transfers dated since.
demoTransfersUpTo :: UTCTime -> [SeedTransfer]
demoTransfersUpTo now =
  -- A list comprehension, like a nested for loop with a filter:
  --   for each month in the window, for each of its transfers,
  --   keep the ones dated at or before now.
  [ t
  | (year, month) <- window
  , t <- monthOf inWindow year month
  , seedAt t <= now
  ]
  where
    -- toGregorian splits a Day into (year, month, day).
    (thisYear, thisMonth, _) = toGregorian (utctDay now)
    window = [addMonths n (thisYear, thisMonth) | n <- [-3 .. 0]]
    inWindow year month = (year, month) `elem` window

-- | (year, month) moved n months forward (or back, for a negative n).
-- Counting months from year 0 turns it into plain arithmetic: "divMod"
-- gives the whole years and the month left over in one step.
addMonths :: Int -> (Integer, Int) -> (Integer, Int)
addMonths n (year, month) =
  let (y, m) = (fromIntegral year * 12 + (month - 1) + n) `divMod` 12
   in (fromIntegral y, m + 1)

-- | One month's transfers, in the order they happened (and are applied, so
-- every balance stays positive at every step). Amounts are in cents:
-- 1200000 is $12,000.00. Times are (day, hour, minute) during US Mountain
-- business hours, which is where the demo companies are.
--
-- "isInWindow" says whether a (year, month) is part of this seed run; the
-- quarterly tax payment needs the month before to have been seeded too.
monthOf :: (Integer -> Int -> Bool) -> Integer -> Int -> [SeedTransfer]
monthOf isInWindow year month =
  [ t "01" (1, 9, 30) "external" "acme-ops" clientA ("Client payment: Initech, " <> name)
  , t "02" (1, 11, 0) "external" "globex-ops" globexClient ("Client payment: Hooli, " <> name)
  , t "03" (1, 16, 0) "acme-ops" "external" 12900 ("Software subscriptions, " <> name)
  , t "04" (9, 14, 30) "external" "acme-ops" clientB ("Client payment: Umbrella, " <> name)
  , t "05" (15, 16, 20) "acme-ops" "globex-ops" 320000 ("Invoice GX-" <> T.drop 2 key)
  , t "06" (20, 10, 0) "globex-ops" "external" 450000 ("Office rent, " <> name)
  , t "07" (24, 9, 0) "acme-ops" "acme-payroll" 1200000 ("Payroll funding, " <> name)
  , t "08" (24, 9, 10) "globex-ops" "globex-payroll" 900000 ("Payroll funding, " <> name)
  , t "09" (25, 9, 30) "acme-payroll" "external" 1150000 ("Payroll run, " <> name)
  , t "10" (25, 9, 40) "globex-payroll" "external" 880000 ("Payroll run, " <> name)
  , t "11" (26, 10, 0) "acme-ops" "acme-tax" (taxSetAside month) ("Tax set-aside, " <> name)
  , t "12" (28, 12, 0) "acme-ops" "acme-savings" 200000 ("Savings transfer, " <> name)
  ]
    -- "++" joins two lists. A list comprehension with no generator, only
    -- conditions, gives a one-item list when they hold and [] otherwise.
    --
    -- At the end of each quarter (March, June, September, December), pay
    -- out what was set aside this month and last. Only when last month is
    -- in this run too, so the money is guaranteed to be in acme-tax.
    ++ [ t "13" (30, 15, 0) "acme-tax" "external" quarterTax ("Quarterly estimated tax, Q" <> T.pack (show (month `div` 3)))
       | month `mod` 3 == 0
       , isInWindow prevYear prevMonth
       ]
  where
    name = monthNames !! (month - 1)
    -- e.g. "2026-07": the year, then the month padded to two digits.
    key = T.pack (show year) <> "-" <> T.justifyRight 2 '0' (T.pack (show month))
    (clientA, clientB, globexClient) = clientPayments month
    (prevYear, prevMonth) = addMonths (-1) (year, month)
    quarterTax = taxSetAside prevMonth + taxSetAside month
    -- Every key includes the month, e.g. "demo:2026-07:01", so every demo
    -- transfer has its own idempotency key.
    t n (day, hour, minute) from to cents memo =
      SeedTransfer ("demo:" <> key <> ":" <> n) from to cents memo (mountainTime year month day hour minute)

-- | (Initech, Umbrella, Hooli) client payments in a given month, in cents.
-- Three patterns that repeat through the year, so months look different.
clientPayments :: Int -> (Integer, Integer, Integer)
clientPayments month = case month `mod` 3 of
  0 -> (2015000, 1310000, 2180000)
  1 -> (1850000, 1240000, 2100000)
  _ -> (1920000, 1105000, 2260000)

-- | Acme sets aside 15% of the month's client payments for tax. "div" is
-- whole-number division, so the result stays in exact cents.
taxSetAside :: Int -> Integer
taxSetAside month =
  let (a, b, _) = clientPayments month
   in (a + b) * 15 `div` 100

monthNames :: [Text]
monthNames =
  [ "January", "February", "March", "April", "May", "June"
  , "July", "August", "September", "October", "November", "December"
  ]

-- | A time in US Mountain time (Denver), as UTC. A UTCTime is a day plus
-- seconds since midnight. Mountain time is 6 hours behind UTC in summer
-- (daylight saving time) and 7 in winter. Browsers then show each time in
-- the viewer's own time zone.
--
-- fromGregorian clamps an impossible day to the month's last, so "day 30"
-- in February is the 28th (or 29th).
mountainTime :: Integer -> Int -> Int -> Int -> Int -> UTCTime
mountainTime year month day hour minute =
  UTCTime date (fromIntegral (((hour + offset) * 60 + minute) * 60))
  where
    date = fromGregorian year month day
    offset = if isDaylightSaving date then 6 else 7

-- | US daylight saving time: from the second Sunday in March to the first
-- Sunday in November. (It switches at 2 a.m. on a Sunday; the demo has no
-- transfers at that hour, so whole days are close enough.)
isDaylightSaving :: Day -> Bool
isDaylightSaving date = date >= nthSunday 2 3 && date < nthSunday 1 11
  where
    (year, _, _) = toGregorian date
    nthSunday :: Integer -> Int -> Day
    nthSunday n month =
      let first = fromGregorian year month 1
          -- Days from the 1st to the first Sunday. fromEnum numbers the
          -- days Monday = 1 to Sunday = 7, so a Sunday the 1st gives 0.
          toSunday = fromIntegral ((7 - fromEnum (dayOfWeek first)) `mod` 7)
       in addDays (toSunday + 7 * (n - 1)) first
