{-# LANGUAGE OverloadedStrings #-}

-- | The tests every UserStore must pass, in memory or in Postgres. Same idea
-- as Support.StoreContract, for users and sessions.
module Support.UserStoreContract
  ( userStoreContract
  ) where

import Data.Time (addUTCTime, getCurrentTime)
import Ledger.Session (TokenHash (..), hashToken)
import Ledger.Store
import Ledger.Types
import Test.Hspec

alice :: User
alice = User (Username "alice") RoleCustomer

userStoreContract :: IO UserStore -> Spec
userStoreContract emptyUsers = do
  it "creates a user once, and finds it with its password hash" $ do
    users <- emptyUsers
    storeCreateUser users alice "hash-1" `shouldReturn` True
    -- Same name again: refused, and the original is untouched.
    storeCreateUser users alice {userRole = RoleAdmin} "hash-2" `shouldReturn` False
    storeFindUser users (Username "alice") `shouldReturn` Just (alice, "hash-1")
    storeFindUser users (Username "nobody") `shouldReturn` Nothing

  it "finds a session until it expires" $ do
    users <- emptyUsers
    _ <- storeCreateUser users alice "hash"
    -- Real clock times: the Postgres store also tidies up sessions that
    -- have expired by the database's own clock.
    now <- getCurrentTime
    let token = hashToken "some-token"
        expires = addUTCTime 3600 now -- one hour from now
    storeCreateSession users token (Username "alice") expires
    storeFindSession users token now `shouldReturn` Just alice
    -- Checked at (or after) the expiry time: gone.
    storeFindSession users token expires `shouldReturn` Nothing
    storeFindSession users token (addUTCTime 1 expires) `shouldReturn` Nothing

  it "forgets a deleted session, and never finds an unknown one" $ do
    users <- emptyUsers
    _ <- storeCreateUser users alice "hash"
    now <- getCurrentTime
    let token = hashToken "another-token"
    storeCreateSession users token (Username "alice") (addUTCTime 3600 now)
    storeDeleteSession users token
    storeFindSession users token now `shouldReturn` Nothing
    storeFindSession users (TokenHash "not-a-real-hash") now `shouldReturn` Nothing
