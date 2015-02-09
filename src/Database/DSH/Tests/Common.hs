{-# LANGUAGE FlexibleContexts #-}

-- | Helpers for the construction of DSH test cases.
module Database.DSH.Tests.Common
    ( makePropEq
    , makePropNotNull
    , makePropDouble
    , makePropDoubles
    , makeEqAssertion
    , testPropertyConn
    , uncurryQ
    ) where

import qualified Data.Text                            as T

import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.Framework.Providers.QuickCheck2
import           Test.HUnit                           (Assertion)
import           Test.HUnit                           (Assertion, assertEqual)
import           Test.QuickCheck
import           Test.QuickCheck.Monadic

import qualified Database.DSH                         as Q
import           Database.DSH.Backend
import           Database.DSH.Compiler

instance Arbitrary T.Text where
  arbitrary = fmap T.pack arbitrary

uncurryQ :: (Q.QA a, Q.QA b) => (Q.Q a -> Q.Q b -> Q.Q c) -> Q.Q (a,b) -> Q.Q c
uncurryQ f = uncurry f . Q.view

eps :: Double
eps = 1.0E-4

-- | A simple property that should hold for a DSH query: Given any
-- input, its result should be the same as the corresponding native
-- Haskell code. 'The same' is defined by a predicate.
makeProp :: (Q.QA a, Q.QA b, Show a, Show b, Backend c)
         => (b -> b -> Bool)
         -> (Q.Q a -> Q.Q b)
         -> (a -> b)
         -> a
         -> c
         -> Property
makeProp eq f1 f2 arg conn = monadicIO $ do
    db <- run $ runQ conn $ f1 (Q.toQ arg)
    let hs = f2 arg
    assert $ db `eq` hs

-- | Compare query result and native result by equality.
makePropEq :: (Eq b, Q.QA a, Q.QA b, Show a, Show b, Backend c)
           => (Q.Q a -> Q.Q b)
           -> (a -> b)
           -> a
           -> c
           -> Property
makePropEq f1 f2 arg conn = makeProp (==) f1 f2 arg conn

-- | Compare query result and native result by equality for a list
-- test input that must not be empty.
makePropNotNull ::  (Eq b, Q.QA a, Q.QA b, Show a, Show b, Backend c)
                => (Q.Q [a] -> Q.Q b)
                -> ([a] -> b)
                -> [a]
                -> c
                -> Property
makePropNotNull q f arg conn = not (null arg) ==> makePropEq q f arg conn

-- | Compare the double query result and native result.
makePropDouble :: (Q.QA a, Show a, Backend c)
               => (Q.Q a -> Q.Q Double)
               -> (a -> Double)
               -> a
               -> c
               -> Property
makePropDouble f1 f2 arg conn = makeProp delta f1 f2 arg conn
  where
    delta a b = abs (a - b) < eps

makePropDoubles :: (Q.QA a, Show a, Backend c)
                => (Q.Q a -> Q.Q [Double])
                -> (a -> [Double])
                -> a
                -> c
                -> Property
makePropDoubles f1 f2 arg conn = makeProp deltaList f1 f2 arg conn
  where
    delta a b       = abs (a - b) < eps
    deltaList as bs = and $ zipWith delta as bs

-- | Equality HUnit assertion
makeEqAssertion :: (Show a, Eq a, Q.QA a, Backend c)
                => String
                -> Q.Q a
                -> a
                -> c
                -> Assertion
makeEqAssertion msg q expRes conn = do
    actualRes <- runQ conn q
    assertEqual msg expRes actualRes

testPropertyConn :: (Show a, Arbitrary a, Backend c)
                 => c -> TestName -> (a -> c -> Property) -> Test
testPropertyConn conn name t = testProperty name (\a -> t a conn)