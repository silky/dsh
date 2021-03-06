module Database.DSH.Tests.LawTests
    ( tests_laws
    ) where

import           Test.QuickCheck
import           Test.QuickCheck.Monadic
import           Test.Tasty

import qualified Database.DSH                   as Q
import           Database.DSH.Backend
import           Database.DSH.Common.VectorLang
import           Database.DSH.Compiler
import           Database.DSH.Tests.Common

tests_laws :: (BackendVector b, VectorLang v) => DSHTestTree (v TExpr TExpr) b
tests_laws codeGen conn = testGroup "List Laws"
    [ testPropertyConn codeGen conn "takedrop" prop_takedrop
    , testPropertyConn codeGen conn "reverse id" prop_reverse_identity
    , testPropertyConn codeGen conn "reverse sort" prop_reverse_sort
    , testPropertyConn codeGen conn "reverse sort tuple" prop_reverse_sort_tuple
    ]

--------------------------------------------------------------------------------
-- Common list laws

prop_takedrop :: (BackendVector b, VectorLang v) => (Integer, [Integer]) -> DSHProperty (v TExpr TExpr) b
prop_takedrop (i, xs) codeGen conn = monadicIO $ do
    let q = Q.take (Q.toQ i) (Q.toQ xs) Q.++ Q.drop (Q.toQ i) (Q.toQ xs)
    res <- run $ runQ codeGen conn q
    assert $ res == xs

prop_reverse_identity :: (BackendVector b, VectorLang v) => [Integer] -> DSHProperty (v TExpr TExpr) b
prop_reverse_identity xs codeGen conn = monadicIO $ do
    let q = Q.reverse $ Q.reverse (Q.toQ xs)
    res <- run $ runQ codeGen conn q
    assert $ res == xs

prop_reverse_sort :: (BackendVector b, VectorLang v) => OrderedList Integer -> DSHProperty (v TExpr TExpr) b
prop_reverse_sort (Ordered xs) codeGen conn = monadicIO $ do
    let q = Q.sortWith id $ Q.reverse (Q.toQ xs)
    res <- run $ runQ codeGen conn q
    assert $ res == xs

prop_reverse_sort_tuple :: (BackendVector b, VectorLang v) => OrderedList (Integer, Integer) -> DSHProperty (v TExpr TExpr) b
prop_reverse_sort_tuple (Ordered xs) codeGen conn = monadicIO $ do
    let q = Q.sortWith id $ Q.reverse (Q.toQ xs)
    res <- run $ runQ codeGen conn q
    assert $ res == xs
