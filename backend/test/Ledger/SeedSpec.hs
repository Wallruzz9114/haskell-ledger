-- | Tests for Ledger.Seed: the demo data is valid, and seeding is repeatable.
module Ledger.SeedSpec (spec) where

import Ledger.Seed
import Ledger.Store
import Ledger.Types
import Test.Hspec

spec :: Spec
spec = do
  it "applies every demo transfer (seedDemoData fails if any is rejected)" $ do
    store <- newInMemoryStore
    seedDemoData store `shouldReturn` ()

  it "leaves every customer account non-negative, and the total at zero" $ do
    store <- newInMemoryStore
    seedDemoData store
    balances <- storeListAccounts store
    -- sum of every balance: double-entry means it's always zero.
    sum (map snd balances) `shouldBe` 0
    [a | (a, bal) <- balances, accountKind a == Customer, bal < 0] `shouldBe` []

  it "changes nothing when run a second time" $ do
    store <- newInMemoryStore
    seedDemoData store
    once <- storeListAccounts store
    seedDemoData store
    storeListAccounts store `shouldReturn` once
