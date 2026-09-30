-- | The in-memory user store must pass the user store contract.
module Ledger.UserStoreSpec (spec) where

import Ledger.Store (newInMemoryUserStore)
import Support.UserStoreContract (userStoreContract)
import Test.Hspec

spec :: Spec
spec = describe "in-memory user store" (userStoreContract newInMemoryUserStore)
