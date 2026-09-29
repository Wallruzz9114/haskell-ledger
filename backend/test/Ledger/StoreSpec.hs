-- | The in-memory (STM) store must pass the store contract.
module Ledger.StoreSpec (spec) where

import Ledger.Store (newInMemoryStore)
import Support.StoreContract (storeContract)
import Test.Hspec

spec :: Spec
spec = describe "in-memory store" (storeContract newInMemoryStore)
