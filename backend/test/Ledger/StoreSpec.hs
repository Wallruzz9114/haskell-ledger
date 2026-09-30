-- | The in-memory (STM) store must pass the store contract.
module Ledger.StoreSpec (spec) where

import Ledger.Store (newInMemoryStore)
import Support.StoreContract (storeContract)
import Test.Hspec

spec :: Spec
spec = describe "in-memory store" (storeContract emptyStore)
  where
    -- The in-memory store doesn't check that owners exist, so there's
    -- nothing to do to "create" a user.
    emptyStore = do
      store <- newInMemoryStore
      pure (store, \_ -> pure ())
