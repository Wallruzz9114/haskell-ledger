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
  , demoAccounts
  , demoTransfers
  , SeedTransfer (..)
  ) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Ledger.Money (mkAmount)
import Ledger.Store
import Ledger.Types

-- | Accounts every ledger needs, demo or not. Today that's just "external",
-- where deposits come from. Safe to call on every startup: if it already
-- exists, opening it again just returns AccountAlreadyExists.
ensureSystemAccounts :: LedgerStore -> IO ()
ensureSystemAccounts store =
  void (storeOpenAccount store (AccountId "external") "External (outside the ledger)" External)

-- | One demo transfer. The key makes it repeatable (see seedDemoData).
data SeedTransfer = SeedTransfer
  { seedKey :: Text
  , seedFrom :: Text
  , seedTo :: Text
  , seedCents :: Integer
  , seedMemo :: Text
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
seedDemoData :: LedgerStore -> IO ()
seedDemoData store = do
  ensureSystemAccounts store
  forM_ demoAccounts $ \(aid, name) ->
    storeOpenAccount store (AccountId aid) name Customer
  forM_ demoTransfers $ \t -> do
    amount <- maybe (fail ("seed amount must be positive: " <> T.unpack (seedKey t))) pure (mkAmount (seedCents t))
    let req = TransferRequest (AccountId (seedFrom t)) (AccountId (seedTo t)) amount (seedMemo t)
    result <- storeTransfer store (Just (IdempotencyKey (seedKey t))) req
    case result of
      Right _ -> pure ()
      Left err -> fail ("seed transfer " <> T.unpack (seedKey t) <> " was rejected: " <> show err)

-- | (id, display name) for every demo customer account.
demoAccounts :: [(Text, Text)]
demoAccounts =
  [ ("acme-ops", "Acme Operating")
  , ("acme-payroll", "Acme Payroll")
  , ("acme-tax", "Acme Tax Reserve")
  , ("acme-savings", "Acme Savings")
  , ("globex-ops", "Globex Operating")
  , ("globex-payroll", "Globex Payroll")
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
  { monthKey :: Text -- "2026-07", part of every idempotency key
  , monthName :: Text -- "July", part of every memo
  , acmeClientA :: Integer -- the two client payments into Acme, in cents
  , acmeClientB :: Integer
  , globexClient :: Integer -- the client payment into Globex
  , invoice :: Text -- Acme's invoice number from Globex
  , quarterEnd :: Bool -- pay the quarter's tax in this month?
  }

months :: [Month]
months =
  [ Month "2026-07" "July" 1850000 1240000 2100000 "GX-1041" False
  , Month "2026-08" "August" 1920000 1105000 2260000 "GX-1057" False
  , Month "2026-09" "September" 2015000 1310000 2180000 "GX-1072" True
  ]

-- | One month's transfers. Amounts are in cents: 1200000 is $12,000.00.
monthOf :: Month -> [SeedTransfer]
monthOf m =
  [ t "01" "external" "acme-ops" (acmeClientA m) ("Client payment: Initech, " <> monthName m)
  , t "02" "external" "acme-ops" (acmeClientB m) ("Client payment: Umbrella, " <> monthName m)
  , t "03" "external" "globex-ops" (globexClient m) ("Client payment: Hooli, " <> monthName m)
  , t "04" "acme-ops" "acme-payroll" 1200000 ("Payroll funding, " <> monthName m)
  , t "05" "acme-payroll" "external" 1150000 ("Payroll run, " <> monthName m)
  , -- Set aside 15% of the month's income for tax. "div" is whole-number
    -- division, so the result stays in exact cents.
    t "06" "acme-ops" "acme-tax" ((acmeClientA m + acmeClientB m) * 15 `div` 100) ("Tax set-aside, " <> monthName m)
  , t "07" "acme-ops" "globex-ops" 320000 ("Invoice " <> invoice m)
  , t "08" "acme-ops" "acme-savings" 200000 ("Savings transfer, " <> monthName m)
  , t "09" "acme-ops" "external" 12900 ("Software subscriptions, " <> monthName m)
  , t "10" "globex-ops" "globex-payroll" 900000 ("Payroll funding, " <> monthName m)
  , t "11" "globex-payroll" "external" 880000 ("Payroll run, " <> monthName m)
  , t "12" "globex-ops" "external" 450000 ("Office rent, " <> monthName m)
  ]
    -- "++" joins two lists. A list comprehension with no generator, only a
    -- condition, gives a one-item list when it's True and [] when False.
    ++ [t "13" "acme-tax" "external" 1000000 "Quarterly estimated tax, Q3" | quarterEnd m]
  where
    t n = SeedTransfer ("seed:" <> monthKey m <> ":" <> n)
