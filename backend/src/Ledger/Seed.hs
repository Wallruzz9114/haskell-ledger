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
  , defaultDemoPassword
  , demoUsers
  , demoAccounts
  , demoTransfers
  , SeedTransfer (..)
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
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

-- | Add the demo accounts and transfers. Safe to run any number of times:
--
--   * opening an account that exists just returns AccountAlreadyExists;
--   * every transfer carries its own idempotency key, so a second run
--     replays the remembered result instead of moving the money again.
--
-- The seed uses the ledger's own idempotency feature to make itself
-- repeatable. If any transfer is REJECTED (say someone edits the list and
-- overdraws an account), it stops with an error instead of carrying on
-- with half the data.
seedDemoData :: Text -> LedgerStore -> UserStore -> IO ()
seedDemoData password store users = do
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
  forM_ demoTransfers $ \t -> do
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

-- | Three months of activity for two companies, oldest first.
--
-- "concatMap f xs" runs f on every element and joins the resulting lists:
-- each month produces its own list of transfers, and we glue them together.
demoTransfers :: [SeedTransfer]
demoTransfers = concatMap monthOf months

-- | The numbers that change from month to month. A record with named fields
-- keeps the list below readable.
data Month = Month
  { monthYear :: Integer
  , monthNumber :: Int -- 7 for July
  , monthName :: Text -- "July", part of every memo
  , acmeClientA :: Integer -- the two client payments into Acme, in cents
  , acmeClientB :: Integer
  , globexClient :: Integer -- the client payment into Globex
  , invoice :: Text -- Acme's invoice number from Globex
  , quarterEnd :: Bool -- pay the quarter's tax in this month?
  }

months :: [Month]
months =
  [ Month 2026 7 "July" 1850000 1240000 2100000 "GX-1041" False
  , Month 2026 8 "August" 1920000 1105000 2260000 "GX-1057" False
  , Month 2026 9 "September" 2015000 1310000 2180000 "GX-1072" True
  ]

-- | One month's transfers, in the order they happened (and are applied, so
-- every balance stays positive at every step). Amounts are in cents:
-- 1200000 is $12,000.00. Times are (day, hour, minute) during US Mountain
-- business hours, which is where the demo companies are.
monthOf :: Month -> [SeedTransfer]
monthOf m =
  [ t "01" (2, 9, 30) "external" "acme-ops" (acmeClientA m) ("Client payment: Initech, " <> monthName m)
  , t "02" (3, 11, 0) "external" "globex-ops" (globexClient m) ("Client payment: Hooli, " <> monthName m)
  , t "03" (9, 14, 30) "external" "acme-ops" (acmeClientB m) ("Client payment: Umbrella, " <> monthName m)
  , t "04" (12, 8, 5) "acme-ops" "external" 12900 ("Software subscriptions, " <> monthName m)
  , t "05" (15, 16, 20) "acme-ops" "globex-ops" 320000 ("Invoice " <> invoice m)
  , t "06" (20, 10, 0) "globex-ops" "external" 450000 ("Office rent, " <> monthName m)
  , t "07" (24, 9, 0) "acme-ops" "acme-payroll" 1200000 ("Payroll funding, " <> monthName m)
  , t "08" (24, 9, 10) "globex-ops" "globex-payroll" 900000 ("Payroll funding, " <> monthName m)
  , t "09" (25, 9, 30) "acme-payroll" "external" 1150000 ("Payroll run, " <> monthName m)
  , t "10" (25, 9, 40) "globex-payroll" "external" 880000 ("Payroll run, " <> monthName m)
  , -- Set aside 15% of the month's income for tax. "div" is whole-number
    -- division, so the result stays in exact cents.
    t "11" (26, 10, 0) "acme-ops" "acme-tax" ((acmeClientA m + acmeClientB m) * 15 `div` 100) ("Tax set-aside, " <> monthName m)
  , t "12" (28, 12, 0) "acme-ops" "acme-savings" 200000 ("Savings transfer, " <> monthName m)
  ]
    -- "++" joins two lists. A list comprehension with no generator, only a
    -- condition, gives a one-item list when it's True and [] when False.
    ++ [t "13" (30, 15, 0) "acme-tax" "external" 1000000 "Quarterly estimated tax, Q3" | quarterEnd m]
  where
    -- The key includes the month, e.g. "seed:2026-07:01", so every demo
    -- transfer has its own idempotency key.
    t n (day, hour, minute) from to cents memo =
      SeedTransfer ("seed:" <> monthKey <> ":" <> n) from to cents memo (at day hour minute)
    monthKey = T.pack (show (monthYear m)) <> "-" <> T.justifyRight 2 '0' (T.pack (show (monthNumber m)))
    -- A UTCTime is a day plus seconds since midnight, in UTC. Mountain
    -- Daylight Time (July to September) is 6 hours behind UTC, so 9:30 in
    -- Denver is 15:30 UTC. Browsers then show each time in the viewer's
    -- own time zone.
    at day hour minute =
      UTCTime (fromGregorian (monthYear m) (monthNumber m) day) (fromIntegral (((hour + 6) * 60 + minute) * 60 :: Int))
