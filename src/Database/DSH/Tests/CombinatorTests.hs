{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}

-- | Tests on individual query combinators.
module Database.DSH.Tests.CombinatorTests
    ( tests_types
    , tests_boolean
    , tests_tuples
    , tests_numerics
    , tests_maybe
    , tests_either
    , tests_lists
    , tests_lifted
    , tests_combinators_hunit
    ) where

import           Test.Framework                       (Test, testGroup)
import           Test.Framework.Providers.HUnit
import           Test.HUnit                           (Assertion)
import           Test.QuickCheck

import           Data.Char
import           Data.Text                            (Text)
import qualified Data.Text                            as Text

import           Data.Either
import           Data.List
import           Data.Maybe
import           GHC.Exts

import qualified Database.DSH                         as Q
import           Database.DSH.Tests.Common
import           Database.DSH.Backend

{-
data D0 = C01 deriving (Eq,Ord,Show)

derive makeArbitrary ''D0
Q.deriveDSH ''D0

data D1 a = C11 a deriving (Eq,Ord,Show)

derive makeArbitrary ''D1
Q.deriveDSH ''D1

data D2 a b = C21 a b b a deriving (Eq,Ord,Show)

derive makeArbitrary ''D2
Q.deriveDSH ''D2

data D3 = C31
        | C32
        deriving (Eq,Ord,Show)

derive makeArbitrary ''D3
Q.deriveDSH ''D3

data D4 a = C41 a
          | C42
          deriving (Eq,Ord,Show)

derive makeArbitrary ''D4
Q.deriveDSH ''D4

data D5 a = C51 a
          | C52
          | C53 a a
          | C54 a a a
          deriving (Eq,Ord,Show)

derive makeArbitrary ''D5
Q.deriveDSH ''D5

data D6 a b c d e = C61 { c611 :: a, c612 :: (a,b,c,d) }
                  | C62
                  | C63 a b
                  | C64 (a,b,c)
                  | C65 a b c d e
                  deriving (Eq,Ord,Show)

derive makeArbitrary ''D6
Q.deriveDSH ''D6

-}

tests_types :: Backend c => c -> Test
tests_types conn = testGroup "Supported Types"
  [ testPropertyConn conn "()"                        prop_unit
  , testPropertyConn conn "Bool"                      prop_bool
  , testPropertyConn conn "Char"                      prop_char
  , testPropertyConn conn "Text"                      prop_text
  , testPropertyConn conn "Integer"                   prop_integer
  , testPropertyConn conn "Double"                    prop_double
  , testPropertyConn conn "[Integer]"                 prop_list_integer_1
  , testPropertyConn conn "[[Integer]]"               prop_list_integer_2
  , testPropertyConn conn "[[[Integer]]]"             prop_list_integer_3
  , testPropertyConn conn "[(Integer, Integer)]"      prop_list_tuple_integer
  , testPropertyConn conn "([], [])"                  prop_tuple_list_integer
  , testPropertyConn conn "(,[])"                     prop_tuple_integer_list
  , testPropertyConn conn "(,[],)"                    prop_tuple_integer_list_integer
  , testPropertyConn conn "Maybe Integer"             prop_maybe_integer
  , testPropertyConn conn "Either Integer Integer"    prop_either_integer
  , testPropertyConn conn "(Int, Int, Int, Int)"      prop_tuple4
  , testPropertyConn conn "(Int, Int, Int, Int, Int)" prop_tuple5
{-
  , testProperty "D0" $ prop_d0
  , testProperty "D1" $ prop_d1
  , testProperty "D2" $ prop_d2
  , testProperty "D3" $ prop_d3
  , testProperty "D4" $ prop_d4
  , testProperty "D5" $ prop_d5
  , testProperty "D6" $ prop_d6
-}
  ]

tests_boolean :: Backend c => c -> Test
tests_boolean conn = testGroup "Equality, Boolean Logic and Ordering"
    [ testPropertyConn conn "&&"                              prop_infix_and
    , testPropertyConn conn "||"                              prop_infix_or
    , testPropertyConn conn "not"                             prop_not
    , testPropertyConn conn "eq"                              prop_eq
    , testPropertyConn conn "neq"                             prop_neq
    , testPropertyConn conn "cond"                            prop_cond
    , testPropertyConn conn "cond tuples"                     prop_cond_tuples
    , testPropertyConn conn "cond ([[Integer]], [[Integer]])" prop_cond_list_tuples
    , testPropertyConn conn "lt"                              prop_lt
    , testPropertyConn conn "lte"                             prop_lte
    , testPropertyConn conn "gt"                              prop_gt
    , testPropertyConn conn "gte"                             prop_gte
    , testPropertyConn conn "min_integer"                     prop_min_integer
    , testPropertyConn conn "min_double"                      prop_min_double
    , testPropertyConn conn "max_integer"                     prop_max_integer
    , testPropertyConn conn "max_double"                      prop_max_double
    ]

tests_tuples :: Backend c => c -> Test
tests_tuples conn = testGroup "Tuples"
    [ testPropertyConn conn "fst"          prop_fst
    , testPropertyConn conn "snd"          prop_snd
    , testPropertyConn conn "fst ([], [])" prop_fst_nested
    , testPropertyConn conn "snd ([], [])" prop_snd_nested
    , testPropertyConn conn "tup3_1"       prop_tup3_1
    , testPropertyConn conn "tup3_2"       prop_tup3_2
    , testPropertyConn conn "tup3_3"       prop_tup3_3
    , testPropertyConn conn "tup4_2"       prop_tup4_2
    , testPropertyConn conn "tup4_4"       prop_tup4_4
    , testPropertyConn conn "tup3_nested"  prop_tup3_nested
    , testPropertyConn conn "tup4_tup3"    prop_tup4_tup3
    ]

tests_numerics :: Backend c => c -> Test
tests_numerics conn = testGroup "Numerics"
    [ testPropertyConn conn "add_integer"         prop_add_integer
    , testPropertyConn conn "add_double"          prop_add_double
    , testPropertyConn conn "mul_integer"         prop_mul_integer
    , testPropertyConn conn "mul_double"          prop_mul_double
    , testPropertyConn conn "div_double"          prop_div_double
    , testPropertyConn conn "integer_to_double"   prop_integer_to_double
    , testPropertyConn conn "integer_to_double_+" prop_integer_to_double_arith
    , testPropertyConn conn "abs_integer"         prop_abs_integer
    , testPropertyConn conn "abs_double"          prop_abs_double
    , testPropertyConn conn "signum_integer"      prop_signum_integer
    , testPropertyConn conn "signum_double"       prop_signum_double
    , testPropertyConn conn "negate_integer"      prop_negate_integer
    , testPropertyConn conn "negate_double"       prop_negate_double
    , testPropertyConn conn "trig_sin"            prop_trig_sin
    , testPropertyConn conn "trig_cos"            prop_trig_cos
    , testPropertyConn conn "trig_tan"            prop_trig_tan
    , testPropertyConn conn "trig_asin"           prop_trig_asin
    , testPropertyConn conn "trig_acos"           prop_trig_acos
    , testPropertyConn conn "trig_atan"           prop_trig_atan
    , testPropertyConn conn "sqrt"                prop_sqrt
    , testPropertyConn conn "log"                 prop_log
    , testPropertyConn conn "exp"                 prop_exp
    ]

tests_maybe :: Backend c => c -> Test
tests_maybe conn = testGroup "Maybe"
    [ testPropertyConn conn "maybe"       prop_maybe
    , testPropertyConn conn "just"        prop_just
    , testPropertyConn conn "isJust"      prop_isJust
    , testPropertyConn conn "isNothing"   prop_isNothing
    , testPropertyConn conn "fromJust"    prop_fromJust
    , testPropertyConn conn "fromMaybe"   prop_fromMaybe
    , testPropertyConn conn "listToMaybe" prop_listToMaybe
    , testPropertyConn conn "maybeToList" prop_maybeToList
    , testPropertyConn conn "catMaybes"   prop_catMaybes
    , testPropertyConn conn "mapMaybe"    prop_mapMaybe
    ]

tests_either :: Backend c => c -> Test
tests_either conn = testGroup "Either"
    [ testPropertyConn conn "left"             prop_left
    , testPropertyConn conn "right"            prop_right
    , testPropertyConn conn "isLeft"           prop_isLeft
    , testPropertyConn conn "isRight"          prop_isRight
    , testPropertyConn conn "either"           prop_either
    , testPropertyConn conn "lefts"            prop_lefts
    , testPropertyConn conn "rights"           prop_rights
    , testPropertyConn conn "partitionEithers" prop_partitionEithers
    ]

tests_lists :: Backend c => c -> Test
tests_lists conn = testGroup "Lists"
    [ testPropertyConn conn "singleton" prop_singleton
    , testPropertyConn conn "head"                         prop_head
    , testPropertyConn conn "tail"                         prop_tail
    , testPropertyConn conn "cons"                         prop_cons
    , testPropertyConn conn "snoc"                         prop_snoc
    , testPropertyConn conn "take"                         prop_take
    , testPropertyConn conn "drop"                         prop_drop
    , testPropertyConn conn "take ++ drop"                 prop_takedrop
    , testPropertyConn conn "map"                          prop_map
    , testPropertyConn conn "filter"                       prop_filter
    , testPropertyConn conn "filter > 42"                  prop_filter_gt
    , testPropertyConn conn "filter > 42 (,[])"            prop_filter_gt_nested
    , testPropertyConn conn "the"                          prop_the
    , testPropertyConn conn "last"                         prop_last
    , testPropertyConn conn "init"                         prop_init
    , testPropertyConn conn "null"                         prop_null
    , testPropertyConn conn "length"                       prop_length
    , testPropertyConn conn "length tuple list"            prop_length_tuple
    , testPropertyConn conn "index [Integer]"              prop_index
    , testPropertyConn conn "index [(Integer, [Integer])]" prop_index_pair
    , testPropertyConn conn "index [[]]"                   prop_index_nest
    , testPropertyConn conn "reverse"                      prop_reverse
    , testPropertyConn conn "reverse [[]]"                 prop_reverse_nest
    , testPropertyConn conn "append"                       prop_append
    , testPropertyConn conn "append nest"                  prop_append_nest
    , testPropertyConn conn "groupWith"                    prop_groupWith
    , testPropertyConn conn "groupWithKey"                 prop_groupWithKey
    , testPropertyConn conn "groupWith length"             prop_groupWith_length
    , testPropertyConn conn "groupWithKey length"          prop_groupWithKey_length
    , testPropertyConn conn "sortWith"                     prop_sortWith
    , testPropertyConn conn "sortWith [(,)]"               prop_sortWith_pair
    , testPropertyConn conn "sortWith [(,[])]"             prop_sortWith_nest
    , testPropertyConn conn "and"                          prop_and
    , testPropertyConn conn "or"                           prop_or
    , testPropertyConn conn "any_zero"                     prop_any_zero
    , testPropertyConn conn "all_zero"                     prop_all_zero
    , testPropertyConn conn "sum_integer"                  prop_sum_integer
    , testPropertyConn conn "sum_double"                   prop_sum_double
    , testPropertyConn conn "avg_integer"                  prop_avg_integer
    , testPropertyConn conn "avg_double"                   prop_avg_double
    , testPropertyConn conn "concat"                       prop_concat
    , testPropertyConn conn "concatMap"                    prop_concatMap
    , testPropertyConn conn "maximum"                      prop_maximum
    , testPropertyConn conn "minimum"                      prop_minimum
    , testPropertyConn conn "splitAt"                      prop_splitAt
    , testPropertyConn conn "takeWhile"                    prop_takeWhile
    , testPropertyConn conn "dropWhile"                    prop_dropWhile
    , testPropertyConn conn "span"                         prop_span
    , testPropertyConn conn "break"                        prop_break
    , testPropertyConn conn "elem"                         prop_elem
    , testPropertyConn conn "notElem"                      prop_notElem
    , testPropertyConn conn "lookup"                       prop_lookup
    , testPropertyConn conn "zip"                          prop_zip
    , testPropertyConn conn "zip3"                         prop_zip3
    , testPropertyConn conn "zipWith"                      prop_zipWith
    , testPropertyConn conn "zipWith3"                     prop_zipWith3
    , testPropertyConn conn "unzip"                        prop_unzip
    , testPropertyConn conn "unzip3"                       prop_unzip3
    , testPropertyConn conn "nub"                          prop_nub
    , testPropertyConn conn "number"                       prop_number
    , testPropertyConn conn "reshape"                      prop_reshape
    , testPropertyConn conn "reshape2"                     prop_reshape2
    , testPropertyConn conn "transpose"                    prop_transpose
    ]

tests_lifted :: Backend c => c -> Test
tests_lifted conn = testGroup "Lifted operations"
    [ testPropertyConn conn "Lifted &&"                             prop_infix_map_and
    , testPropertyConn conn "Lifted ||"                             prop_infix_map_or
    , testPropertyConn conn "Lifted not"                            prop_map_not
    , testPropertyConn conn "Lifted eq"                             prop_map_eq
    , testPropertyConn conn "Lifted neq"                            prop_map_neq
    , testPropertyConn conn "Lifted cond"                           prop_map_cond
    , testPropertyConn conn "Lifted cond tuples"                    prop_map_cond_tuples
    , testPropertyConn conn "Lifted cond + concat"                  prop_concatmapcond
    , testPropertyConn conn "Lifted lt"                             prop_map_lt
    , testPropertyConn conn "Lifted lte"                            prop_map_lte
    , testPropertyConn conn "Lifted gt"                             prop_map_gt
    , testPropertyConn conn "Lifted gte"                            prop_map_gte
    , testPropertyConn conn "Lifted cons"                           prop_map_cons
    , testPropertyConn conn "Lifted concat"                         prop_map_concat
    , testPropertyConn conn "Lifted fst"                            prop_map_fst
    , testPropertyConn conn "Lifted snd"                            prop_map_snd
    , testPropertyConn conn "Lifted the"                            prop_map_the
    --, testPropertyConn conn "Lifed and"                           prop_map_and
    , testPropertyConn conn "map (map (*2))"                        prop_map_map_mul
    , testPropertyConn conn "map (map (map (*2)))"                  prop_map_map_map_mul
    , testPropertyConn conn "map (\\x -> map (\\y -> x + y) ..) .." prop_map_map_add
    , testPropertyConn conn "Lifted groupWith"                      prop_map_groupWith
    , testPropertyConn conn "Lifted groupWithKey"                   prop_map_groupWithKey
    , testPropertyConn conn "Lifted sortWith"                       prop_map_sortWith
    , testPropertyConn conn "Lifted sortWith [(,)]"                 prop_map_sortWith_pair
    , testPropertyConn conn "Lifted sortWith [(,[])]"               prop_map_sortWith_nest
    , testPropertyConn conn "Lifted sortWith length"                prop_map_sortWith_length
    , testPropertyConn conn "Lifted groupWithKey length"            prop_map_groupWithKey_length
    , testPropertyConn conn "Lifted length"                         prop_map_length
    , testPropertyConn conn "Lifted length on [[(a,b)]]"            prop_map_length_tuple
    , testPropertyConn conn "Sortwith length nested"                prop_sortWith_length_nest
    , testPropertyConn conn "GroupWithKey length nested"            prop_groupWithKey_length_nest
    , testPropertyConn conn "Lift minimum"                          prop_map_minimum
    , testPropertyConn conn "map (map minimum)"                     prop_map_map_minimum
    , testPropertyConn conn "Lift maximum"                          prop_map_maximum
    , testPropertyConn conn "map (map maximum)"                     prop_map_map_maximum
    , testPropertyConn conn "map integer_to_double"                 prop_map_integer_to_double
    , testPropertyConn conn "map tail"                              prop_map_tail
    , testPropertyConn conn "map unzip"                             prop_map_unzip
    , testPropertyConn conn "map reverse"                           prop_map_reverse
    , testPropertyConn conn "map reverse [[]]"                      prop_map_reverse_nest
    , testPropertyConn conn "map and"                               prop_map_and
    , testPropertyConn conn "map (map and)"                         prop_map_map_and
    , testPropertyConn conn "map sum"                               prop_map_sum
    , testPropertyConn conn "map avg"                               prop_map_avg
    , testPropertyConn conn "map (map sum)"                         prop_map_map_sum
    , testPropertyConn conn "map or"                                prop_map_or
    , testPropertyConn conn "map (map or)"                          prop_map_map_or
    , testPropertyConn conn "map any zero"                          prop_map_any_zero
    , testPropertyConn conn "map all zero"                          prop_map_all_zero
    , testPropertyConn conn "map filter"                            prop_map_filter
    , testPropertyConn conn "map filter > 42"                       prop_map_filter_gt
    , testPropertyConn conn "map filter > 42 (,[])"                 prop_map_filter_gt_nested
    , testPropertyConn conn "map append"                            prop_map_append
    , testPropertyConn conn "map index"                             prop_map_index
    , testPropertyConn conn "map index [[]]"                        prop_map_index_nest
    , testPropertyConn conn "map init"                              prop_map_init
    , testPropertyConn conn "map last"                              prop_map_last
    , testPropertyConn conn "map null"                              prop_map_null
    , testPropertyConn conn "map nub"                               prop_map_nub
    , testPropertyConn conn "map snoc"                              prop_map_snoc
    , testPropertyConn conn "map take"                              prop_map_take
    , testPropertyConn conn "map drop"                              prop_map_drop
    , testPropertyConn conn "map zip"                               prop_map_zip
    , testPropertyConn conn "map takeWhile"                         prop_map_takeWhile
    , testPropertyConn conn "map dropWhile"                         prop_map_dropWhile
    , testPropertyConn conn "map span"                              prop_map_span
    , testPropertyConn conn "map break"                             prop_map_break
    , testPropertyConn conn "map number"                            prop_map_number
    , testPropertyConn conn "map reshape"                           prop_map_reshape
    , testPropertyConn conn "map reshape2"                          prop_map_reshape2
    -- , testPropertyConn conn "map transpose"                      prop_map_transpose
    , testPropertyConn conn "map sin"                               prop_map_trig_sin
    , testPropertyConn conn "map cos"                               prop_map_trig_cos
    , testPropertyConn conn "map tan"                               prop_map_trig_tan
    , testPropertyConn conn "map asin"                              prop_map_trig_asin
    , testPropertyConn conn "map acos"                              prop_map_trig_acos
    , testPropertyConn conn "map atan"                              prop_map_trig_atan
    , testPropertyConn conn "map log"                               prop_map_log
    , testPropertyConn conn "map exp"                               prop_map_exp
    , testPropertyConn conn "map sqrt"                              prop_map_sqrt
    ]

tests_combinators_hunit :: Backend c => c -> Test
tests_combinators_hunit conn = testGroup "HUnit combinators"
    [ testCase "hnegative_sum"     (hnegative_sum conn)
    , testCase "hnegative_map_sum" (hnegative_map_sum conn)
    , testCase "hmap_transpose"    (hmap_transpose conn)
    ]

-- * Supported Types

prop_unit :: Backend c => () -> c -> Property
prop_unit = makePropEq id id

prop_bool :: Backend c => Bool -> c -> Property
prop_bool = makePropEq id id

prop_integer :: Backend c => Integer -> c -> Property
prop_integer = makePropEq id id

prop_double :: Backend c => Double -> c -> Property
prop_double = makePropDouble id id

prop_char :: Backend c => Char -> c -> Property
prop_char c conn = isPrint c ==> makePropEq id id c conn

prop_text :: Backend c => Text -> c -> Property
prop_text t conn = Text.all isPrint t ==> makePropEq id id t conn

prop_list_integer_1 :: Backend c => [Integer] -> c -> Property
prop_list_integer_1 = makePropEq id id

prop_list_integer_2 :: Backend c => [[Integer]] -> c -> Property
prop_list_integer_2 = makePropEq id id

prop_list_integer_3 :: Backend c => [[[Integer]]] -> c -> Property
prop_list_integer_3 = makePropEq id id

prop_list_tuple_integer :: Backend c => [(Integer, Integer)] -> c -> Property
prop_list_tuple_integer = makePropEq id id

prop_maybe_integer :: Backend c => Maybe Integer -> c -> Property
prop_maybe_integer = makePropEq id id

prop_tuple_list_integer :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_tuple_list_integer = makePropEq id id

prop_tuple_integer_list :: Backend c => (Integer, [Integer]) -> c -> Property
prop_tuple_integer_list = makePropEq id id

prop_tuple_integer_list_integer :: Backend c => (Integer, [Integer], Integer) -> c -> Property
prop_tuple_integer_list_integer = makePropEq id id

prop_either_integer :: Backend c => Either Integer Integer -> c -> Property
prop_either_integer = makePropEq id id

prop_tuple4 :: Backend c => [(Integer, Integer, Integer, Integer)] -> c -> Property
prop_tuple4 = makePropEq (Q.map (\(Q.view -> (a, b, c, d)) -> Q.tup4 (a + c) (b - d) b d))
                         (map (\(a, b, c, d) -> (a + c, b - d, b, d)))

prop_tuple5 :: Backend c => [(Integer, Integer, Integer, Integer, Integer)] -> c -> Property
prop_tuple5 = makePropEq (Q.map (\(Q.view -> (a, _, c, _, e)) -> Q.tup3 a c e))
                         (map (\(a, _, c, _, e) -> (a, c, e)))

-- {-

-- prop_d0 :: Backend c => D0 -> c -> Property
-- prop_d0 = makePropEq id id

-- prop_d1 :: Backend c => D1 Integer -> c -> Property
-- prop_d1 = makePropEq id id

-- prop_d2 :: Backend c => D2 Integer Integer -> c -> Property
-- prop_d2 = makePropEq id id

-- prop_d3 :: Backend c => D3 -> c -> Property
-- prop_d3 = makePropEq id id

-- prop_d4 :: Backend c => D4 Integer -> c -> Property
-- prop_d4 = makePropEq id id

-- prop_d5 :: Backend c => D5 Integer -> c -> Property
-- prop_d5 = makePropEq id id

-- prop_d6 :: Backend c => D6 Integer Integer Integer Integer Integer -> c -> Property
-- prop_d6 = makePropEq id id

-- -}

-- * Equality, Boolean Logic and Ordering

prop_infix_and :: Backend c => (Bool,Bool) -> c -> Property
prop_infix_and = makePropEq (uncurryQ (Q.&&)) (uncurry (&&))

prop_infix_map_and :: Backend c => (Bool, [Bool]) -> c -> Property
prop_infix_map_and = makePropEq (\x -> Q.map ((Q.fst x) Q.&&) $ Q.snd x) (\(x,xs) -> map (x &&) xs)

prop_infix_or :: Backend c => (Bool,Bool) -> c -> Property
prop_infix_or = makePropEq (uncurryQ (Q.||)) (uncurry (||))

prop_infix_map_or :: Backend c => (Bool, [Bool]) -> c -> Property
prop_infix_map_or = makePropEq (\x -> Q.map ((Q.fst x) Q.||) $ Q.snd x) (\(x,xs) -> map (x ||) xs)

prop_not :: Backend c => Bool -> c -> Property
prop_not = makePropEq Q.not not

prop_map_not :: Backend c => [Bool] -> c -> Property
prop_map_not = makePropEq (Q.map Q.not) (map not)

prop_eq :: Backend c => (Integer,Integer) -> c -> Property
prop_eq = makePropEq (uncurryQ (Q.==)) (uncurry (==))

prop_map_eq :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_eq = makePropEq (\x -> Q.map ((Q.fst x) Q.==) $ Q.snd x) (\(x,xs) -> map (x ==) xs)

prop_neq :: Backend c => (Integer,Integer) -> c -> Property
prop_neq = makePropEq (uncurryQ (Q./=)) (uncurry (/=))

prop_map_neq :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_neq = makePropEq (\x -> Q.map ((Q.fst x) Q./=) $ Q.snd x) (\(x,xs) -> map (x /=) xs)

prop_cond :: Backend c => Bool -> c -> Property
prop_cond = makePropEq (\b -> Q.cond b 0 1) (\b -> if b then (0 :: Integer) else 1)

prop_cond_tuples :: Backend c => (Bool, (Integer, Integer)) -> c -> Property
prop_cond_tuples = makePropEq (\b -> Q.cond (Q.fst b)
                                          (Q.pair (Q.fst $ Q.snd b) (Q.fst $ Q.snd b))
                                          (Q.pair (Q.snd $ Q.snd b) (Q.snd $ Q.snd b)))
                            (\b -> if fst b
                                   then (fst $ snd b, fst $ snd b)
                                   else (snd $ snd b, snd $ snd b))

prop_cond_list_tuples :: Backend c => (Bool, ([[Integer]], [[Integer]])) -> c -> Property
prop_cond_list_tuples = makePropEq (\b -> Q.cond (Q.fst b)
                                               (Q.pair (Q.fst $ Q.snd b) (Q.fst $ Q.snd b))
                                               (Q.pair (Q.snd $ Q.snd b) (Q.snd $ Q.snd b)))
                                 (\b -> if fst b
                                        then (fst $ snd b, fst $ snd b)
                                        else (snd $ snd b, snd $ snd b))

prop_map_cond :: Backend c => [Bool] -> c -> Property
prop_map_cond = makePropEq (Q.map (\b -> Q.cond b (0 :: Q.Q Integer) 1))
                         (map (\b -> if b then 0 else 1))

prop_map_cond_tuples :: Backend c => [Bool] -> c -> Property
prop_map_cond_tuples = makePropEq (Q.map (\b -> Q.cond b
                                                     (Q.toQ (0, 10) :: Q.Q (Integer, Integer))
                                                     (Q.toQ (1, 11))))
                                (map (\b -> if b
                                            then (0, 10)
                                            else (1, 11)))

prop_concatmapcond :: Backend c => [Integer] -> c -> Property
prop_concatmapcond l1 conn =
        -- FIXME remove precondition as soon as X100 is fixed
    (not $ null l1)
    ==>
    makePropEq q n l1 conn
        where q l = Q.concatMap (\x -> Q.cond ((Q.>) x (Q.toQ 0)) (x Q.<| el) el) l
              n l = concatMap (\x -> if x > 0 then [x] else []) l
              el = Q.toQ []

prop_lt :: Backend c => (Integer, Integer) -> c -> Property
prop_lt = makePropEq (uncurryQ (Q.<)) (uncurry (<))

prop_map_lt :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_lt = makePropEq (\x -> Q.map ((Q.fst x) Q.<) $ Q.snd x) (\(x,xs) -> map (x <) xs)

prop_lte :: Backend c => (Integer, Integer) -> c -> Property
prop_lte = makePropEq (uncurryQ (Q.<=)) (uncurry (<=))

prop_map_lte :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_lte = makePropEq (\x -> Q.map ((Q.fst x) Q.<=) $ Q.snd x) (\(x,xs) -> map (x <=) xs)

prop_gt :: Backend c => (Integer, Integer) -> c -> Property
prop_gt = makePropEq (uncurryQ (Q.>)) (uncurry (>))

prop_map_gt :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_gt = makePropEq (\x -> Q.map ((Q.fst x) Q.>) $ Q.snd x) (\(x,xs) -> map (x >) xs)

prop_gte :: Backend c => (Integer, Integer) -> c -> Property
prop_gte = makePropEq (uncurryQ (Q.>=)) (uncurry (>=))

prop_map_gte :: Backend c => (Integer, [Integer]) -> c -> Property
prop_map_gte = makePropEq (\x -> Q.map ((Q.fst x) Q.>=) $ Q.snd x) (\(x,xs) -> map (x >=) xs)

prop_min_integer :: Backend c => (Integer,Integer) -> c -> Property
prop_min_integer = makePropEq (uncurryQ Q.min) (uncurry min)

prop_max_integer :: Backend c => (Integer,Integer) -> c -> Property
prop_max_integer = makePropEq (uncurryQ Q.max) (uncurry max)

prop_min_double :: Backend c => (Double,Double) -> c -> Property
prop_min_double = makePropDouble (uncurryQ Q.min) (uncurry min)

prop_max_double :: Backend c => (Double,Double) -> c -> Property
prop_max_double = makePropDouble (uncurryQ Q.max) (uncurry max)

-- * Maybe

prop_maybe :: Backend c => (Integer, Maybe Integer) -> c -> Property
prop_maybe =  makePropEq (\a -> Q.maybe (Q.fst a) id (Q.snd a)) (\(i,mi) -> maybe i id mi)

prop_just :: Backend c => Integer -> c -> Property
prop_just = makePropEq Q.just Just

prop_isJust :: Backend c => Maybe Integer -> c -> Property
prop_isJust = makePropEq Q.isJust isJust

prop_isNothing :: Backend c => Maybe Integer -> c -> Property
prop_isNothing = makePropEq Q.isNothing isNothing

prop_fromJust :: Backend c => Maybe Integer -> c -> Property
prop_fromJust mi conn = isJust mi ==> makePropEq Q.fromJust fromJust mi conn

prop_fromMaybe :: Backend c => (Integer,Maybe Integer) -> c -> Property
prop_fromMaybe = makePropEq (uncurryQ Q.fromMaybe) (uncurry fromMaybe)

prop_listToMaybe :: Backend c => [Integer] -> c -> Property
prop_listToMaybe = makePropEq Q.listToMaybe listToMaybe

prop_maybeToList :: Backend c => Maybe Integer -> c -> Property
prop_maybeToList = makePropEq Q.maybeToList maybeToList

prop_catMaybes :: Backend c => [Maybe Integer] -> c -> Property
prop_catMaybes = makePropEq Q.catMaybes catMaybes

prop_mapMaybe :: Backend c => [Maybe Integer] -> c -> Property
prop_mapMaybe = makePropEq (Q.mapMaybe id) (mapMaybe id)

-- * Either

prop_left :: Backend c => Integer -> c -> Property
prop_left = makePropEq (Q.left :: Q.Q Integer -> Q.Q (Either Integer Integer)) Left

prop_right :: Backend c => Integer -> c -> Property
prop_right = makePropEq (Q.right :: Q.Q Integer -> Q.Q (Either Integer Integer)) Right

prop_isLeft :: Backend c => Either Integer Integer -> c -> Property
prop_isLeft = makePropEq Q.isLeft (\e -> case e of {Left _ -> True; Right _ -> False;})

prop_isRight :: Backend c => Either Integer Integer -> c -> Property
prop_isRight = makePropEq Q.isRight (\e -> case e of {Left _ -> False; Right _ -> True;})

prop_either :: Backend c => Either Integer Integer -> c -> Property
prop_either =  makePropEq (Q.either id id) (either id id)

prop_lefts :: Backend c => [Either Integer Integer] -> c -> Property
prop_lefts =  makePropEq Q.lefts lefts

prop_rights :: Backend c => [Either Integer Integer] -> c -> Property
prop_rights =  makePropEq Q.rights rights

prop_partitionEithers :: Backend c => [Either Integer Integer] -> c -> Property
prop_partitionEithers =  makePropEq Q.partitionEithers partitionEithers

-- * Lists

prop_cons :: Backend c => (Integer, [Integer]) -> c -> Property
prop_cons = makePropEq (uncurryQ (Q.<|)) (uncurry (:))

prop_map_cons :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_cons = makePropEq (\x -> Q.map ((Q.fst x) Q.<|) $ Q.snd x)
                         (\(x,xs) -> map (x:) xs)

prop_snoc :: Backend c => ([Integer], Integer) -> c -> Property
prop_snoc = makePropEq (uncurryQ (Q.|>)) (\(a,b) -> a ++ [b])

prop_map_snoc :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_map_snoc = makePropEq (\z -> Q.map ((Q.fst z) Q.|>) (Q.snd z)) (\(a,b) -> map (\z -> a ++ [z]) b)

prop_singleton :: Backend c => Integer -> c -> Property
prop_singleton = makePropEq Q.singleton (: [])

prop_head :: Backend c => [Integer] -> c -> Property
prop_head = makePropNotNull Q.head head

prop_tail :: Backend c => [Integer] -> c -> Property
prop_tail = makePropNotNull Q.tail tail

prop_last :: Backend c => [Integer] -> c -> Property
prop_last = makePropNotNull Q.last last

prop_map_last :: Backend c => [[Integer]] -> c -> Property
prop_map_last ps conn =
    and (map ((>0) . length) ps)
    ==>
    makePropEq (Q.map Q.last) (map last) ps conn

prop_init :: Backend c => [Integer] -> c -> Property
prop_init = makePropNotNull Q.init init

prop_map_init  :: Backend c => [[Integer]] -> c -> Property
prop_map_init ps conn =
    and (map ((>0) . length) ps)
    ==>
    makePropEq (Q.map Q.init) (map init) ps conn

prop_the   :: Backend c => (Int, Integer) -> c -> Property
prop_the (n, i) conn =
    n > 0
    ==>
    let l = replicate n i in makePropEq Q.head the l conn

prop_map_the :: Backend c => [(Int, Integer)] -> c -> Property
prop_map_the ps conn =
    let ps' = filter ((>0) . fst) ps in (length ps') > 0
    ==>
    let xss = map (\(n, i) -> replicate n i) ps'
    in makePropEq (Q.map Q.head) (map the) xss conn

prop_map_tail :: Backend c => [[Integer]] -> c -> Property
prop_map_tail ps conn =
    and [length p > 0 | p <- ps]
    ==>
    makePropEq (Q.map Q.tail) (map tail) ps conn

prop_index :: Backend c => ([Integer], Integer)  -> c -> Property
prop_index (l, i) conn =
    i > 0 && i < fromIntegral (length l)
    ==>
    makePropEq (uncurryQ (Q.!!))
               (\(a,b) -> a !! fromIntegral b)
               (l, i)
               conn

prop_index_pair :: Backend c => ([(Integer, [Integer])], Integer) -> c -> Property
prop_index_pair (l, i) conn =
    i > 0 && i < fromIntegral (length l)
    ==>
    makePropEq (uncurryQ (Q.!!))
               (\(a,b) -> a !! fromIntegral b)
               (l, i)
               conn

prop_index_nest :: Backend c => ([[Integer]], Integer)  -> c -> Property
prop_index_nest (l, i) conn =
    i > 0 && i < fromIntegral (length l)
    ==>
    makePropEq (uncurryQ (Q.!!))
               (\(a,b) -> a !! fromIntegral b)
               (l, i)
               conn

prop_map_index :: Backend c => ([Integer], [Integer])  -> c -> Property
prop_map_index (l, is) conn =
    and [i >= 0 && i < 2 * fromIntegral (length l) | i <-  is]
    ==>
    makePropEq (\z -> Q.map (((Q.fst z) Q.++ (Q.fst z) Q.++ (Q.fst z)) Q.!!)
                            (Q.snd z))
               (\(a,b) -> map ((a ++ a ++ a) !!)
                              (map fromIntegral b))
               (l, is)
               conn

prop_map_index_nest :: Backend c => ([[Integer]], [Integer])  -> c -> Property
prop_map_index_nest (l, is) conn =
    and [i >= 0 && i < 3 * fromIntegral (length l) | i <-  is]
    ==> makePropEq (\z -> Q.map (((Q.fst z) Q.++ (Q.fst z) Q.++ (Q.fst z)) Q.!!)
                                (Q.snd z))
                   (\(a,b) -> map ((a ++ a ++ a) !!) (map fromIntegral b))
                   (l, is)
                   conn

prop_take :: Backend c => (Integer, [Integer]) -> c -> Property
prop_take = makePropEq (uncurryQ Q.take) (\(n,l) -> take (fromIntegral n) l)

prop_map_take :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_take = makePropEq (\z -> Q.map (Q.take $ Q.fst z) $ Q.snd z)
                           (\(n,l) -> map (take (fromIntegral n)) l)

prop_drop :: Backend c => (Integer, [Integer]) -> c -> Property
prop_drop = makePropEq (uncurryQ Q.drop) (\(n,l) -> drop (fromIntegral n) l)

prop_map_drop :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_drop = makePropEq (\z -> Q.map (Q.drop $ Q.fst z) $ Q.snd z)
                           (\(n,l) -> map (drop (fromIntegral n)) l)

prop_takedrop :: Backend c => (Integer, [Integer]) -> c -> Property
prop_takedrop = makePropEq takedrop_q takedrop
  where
    takedrop_q p    = Q.append ((Q.take (Q.fst p)) (Q.snd p))
                               ((Q.drop (Q.fst p)) (Q.snd p))
    takedrop (n, l) = (take (fromIntegral n) l)
                      ++
                      (drop (fromIntegral n) l)

prop_map :: Backend c => [Integer] -> c -> Property
prop_map = makePropEq (Q.map id) (map id)

prop_map_map_mul :: Backend c => [[Integer]] -> c -> Property
prop_map_map_mul = makePropEq (Q.map (Q.map (*2))) (map (map (*2)))

prop_map_map_add :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_map_map_add = makePropEq (\z -> Q.map (\x -> (Q.map (\y -> x + y) $ Q.snd z))
                                           (Q.fst z))
                              (\(l,r) -> map (\x -> map (\y -> x + y) r) l)

prop_map_map_map_mul :: Backend c => [[[Integer]]] -> c -> Property
prop_map_map_map_mul = makePropEq (Q.map (Q.map (Q.map (*2)))) (map (map (map (*2))))

prop_append :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_append = makePropEq (uncurryQ (Q.++)) (uncurry (++))

prop_append_nest :: Backend c => ([[Integer]], [[Integer]]) -> c -> Property
prop_append_nest = makePropEq (uncurryQ (Q.append)) (\(a,b) -> a ++ b)

prop_map_append :: Backend c => ([Integer], [[Integer]]) -> c -> Property
prop_map_append = makePropEq (\z -> Q.map (Q.fst z Q.++) (Q.snd z)) (\(a,b) -> map (a ++) b)

prop_filter :: Backend c => [Integer] -> c -> Property
prop_filter = makePropEq (Q.filter (const $ Q.toQ True)) (filter $ const True)

prop_filter_gt :: Backend c => [Integer] -> c -> Property
prop_filter_gt = makePropEq (Q.filter (Q.> 42)) (filter (> 42))

prop_filter_gt_nested :: Backend c => [(Integer, [Integer])] -> c -> Property
prop_filter_gt_nested = makePropEq (Q.filter ((Q.> 42) . Q.fst)) (filter ((> 42) . fst))

prop_map_filter :: Backend c => [[Integer]] -> c -> Property
prop_map_filter = makePropEq (Q.map (Q.filter (const $ Q.toQ True))) (map (filter $ const True))

prop_map_filter_gt :: Backend c => [[Integer]] -> c -> Property
prop_map_filter_gt = makePropEq (Q.map (Q.filter (Q.> 42))) (map (filter (> 42)))

prop_map_filter_gt_nested :: Backend c => [[(Integer, [Integer])]] -> c -> Property
prop_map_filter_gt_nested = makePropEq (Q.map (Q.filter ((Q.> 42) . Q.fst))) (map (filter ((> 42) . fst)))

prop_groupWith :: Backend c => [Integer] -> c -> Property
prop_groupWith = makePropEq (Q.groupWith id) (groupWith id)

groupWithKey :: Ord b => (a -> b) -> [a] -> [(b, [a])]
groupWithKey p as = map (\g -> (the $ map p g, g)) $ groupWith p as

prop_groupWithKey :: Backend c => [Integer] -> c -> Property
prop_groupWithKey = makePropEq (Q.groupWithKey id) (groupWithKey id)

prop_map_groupWith :: Backend c => [[Integer]] -> c -> Property
prop_map_groupWith = makePropEq (Q.map (Q.groupWith id)) (map (groupWith id))

prop_map_groupWithKey :: Backend c => [[Integer]] -> c -> Property
prop_map_groupWithKey = makePropEq (Q.map (Q.groupWithKey id)) (map (groupWithKey id))

prop_groupWith_length :: Backend c => [[Integer]] -> c -> Property
prop_groupWith_length = makePropEq (Q.groupWith Q.length) (groupWith length)

prop_groupWithKey_length :: Backend c => [[Integer]] -> c -> Property
prop_groupWithKey_length = makePropEq (Q.groupWithKey Q.length) (groupWithKey (fromIntegral . length))

prop_sortWith  :: Backend c => [Integer] -> c -> Property
prop_sortWith = makePropEq (Q.sortWith id) (sortWith id)

prop_sortWith_pair :: Backend c => [(Integer, Integer)] -> c -> Property
prop_sortWith_pair = makePropEq (Q.sortWith Q.fst) (sortWith fst)

prop_sortWith_nest  :: Backend c => [(Integer, [Integer])] -> c -> Property
prop_sortWith_nest = makePropEq (Q.sortWith Q.fst) (sortWith fst)

prop_map_sortWith :: Backend c => [[Integer]] -> c -> Property
prop_map_sortWith = makePropEq (Q.map (Q.sortWith id)) (map (sortWith id))

prop_map_sortWith_pair :: Backend c => [[(Integer, Integer)]] -> c -> Property
prop_map_sortWith_pair = makePropEq (Q.map (Q.sortWith Q.fst)) (map (sortWith fst))

prop_map_sortWith_nest :: Backend c => [[(Integer, [Integer])]] -> c -> Property
prop_map_sortWith_nest = makePropEq (Q.map (Q.sortWith Q.fst)) (map (sortWith fst))

prop_map_sortWith_length :: Backend c => [[[Integer]]] -> c -> Property
prop_map_sortWith_length = makePropEq (Q.map (Q.sortWith Q.length)) (map (sortWith length))

prop_map_groupWith_length :: Backend c => [[[Integer]]] -> c -> Property
prop_map_groupWith_length = makePropEq (Q.map (Q.groupWith Q.length)) (map (groupWith length))

prop_map_groupWithKey_length :: Backend c => [[[Integer]]] -> c -> Property
prop_map_groupWithKey_length = makePropEq (Q.map (Q.groupWithKey Q.length)) (map (groupWithKey (fromIntegral . length)))

prop_sortWith_length_nest  :: Backend c => [[[Integer]]] -> c -> Property
prop_sortWith_length_nest = makePropEq (Q.sortWith Q.length) (sortWith length)

prop_groupWith_length_nest :: Backend c => [[[Integer]]] -> c -> Property
prop_groupWith_length_nest = makePropEq (Q.groupWith Q.length) (groupWith length)

prop_groupWithKey_length_nest :: Backend c => [[[Integer]]] -> c -> Property
prop_groupWithKey_length_nest = makePropEq (Q.groupWithKey Q.length) (groupWithKey (fromIntegral . length))

prop_null :: Backend c => [Integer] -> c -> Property
prop_null = makePropEq Q.null null

prop_map_null :: Backend c => [[Integer]] -> c -> Property
prop_map_null = makePropEq (Q.map Q.null) (map null)

prop_length :: Backend c => [Integer] -> c -> Property
prop_length = makePropEq Q.length ((fromIntegral :: Int -> Integer) . length)

prop_length_tuple :: Backend c => [(Integer, Integer)] -> c -> Property
prop_length_tuple = makePropEq Q.length (fromIntegral . length)

prop_map_length :: Backend c => [[Integer]] -> c -> Property
prop_map_length = makePropEq (Q.map Q.length) (map (fromIntegral . length))

prop_map_minimum :: Backend c => [[Integer]] -> c -> Property
prop_map_minimum ps conn =
    and (map (\p -> length p > 0) ps)
    ==>
    makePropEq (Q.map Q.minimum) (map (fromIntegral . minimum)) ps conn

prop_map_maximum :: Backend c => [[Integer]] -> c -> Property
prop_map_maximum ps conn =
    and (map (\p -> length p > 0) ps)
    ==>
    makePropEq (Q.map Q.maximum) (map (fromIntegral . maximum)) ps conn

prop_map_map_minimum :: Backend c => [[[Integer]]] -> c -> Property
prop_map_map_minimum ps conn =
    and (map (and . map (\p -> length p > 0)) ps)
    ==>
    makePropEq (Q.map (Q.map Q.minimum)) (map (map(fromIntegral . minimum))) ps conn

prop_map_map_maximum :: Backend c => [[[Integer]]] -> c -> Property
prop_map_map_maximum ps conn =
    and (map (and . map (\p -> length p > 0)) ps)
    ==>
    makePropEq (Q.map (Q.map Q.maximum)) (map (map(fromIntegral . maximum))) ps conn


prop_map_length_tuple :: Backend c => [[(Integer, Integer)]] -> c -> Property
prop_map_length_tuple = makePropEq (Q.map Q.length) (map (fromIntegral . length))

prop_reverse :: Backend c => [Integer] -> c -> Property
prop_reverse = makePropEq Q.reverse reverse

prop_reverse_nest :: Backend c => [[Integer]] -> c -> Property
prop_reverse_nest = makePropEq Q.reverse reverse

prop_map_reverse :: Backend c => [[Integer]] -> c -> Property
prop_map_reverse = makePropEq (Q.map Q.reverse) (map reverse)

prop_map_reverse_nest :: Backend c => [[[Integer]]] -> c -> Property
prop_map_reverse_nest = makePropEq (Q.map Q.reverse) (map reverse)

prop_and :: Backend c => [Bool] -> c -> Property
prop_and = makePropEq Q.and and

prop_map_and :: Backend c => [[Bool]] -> c -> Property
prop_map_and = makePropEq (Q.map Q.and) (map and)

prop_map_map_and :: Backend c => [[[Bool]]] -> c -> Property
prop_map_map_and = makePropEq (Q.map (Q.map Q.and)) (map (map and))

prop_or :: Backend c => [Bool] -> c -> Property
prop_or = makePropEq Q.or or

prop_map_or :: Backend c => [[Bool]] -> c -> Property
prop_map_or = makePropEq (Q.map Q.or) (map or)

prop_map_map_or :: Backend c => [[[Bool]]] -> c -> Property
prop_map_map_or = makePropEq (Q.map (Q.map Q.or)) (map (map or))

prop_any_zero :: Backend c => [Integer] -> c -> Property
prop_any_zero = makePropEq (Q.any (Q.== 0)) (any (== 0))

prop_map_any_zero :: Backend c => [[Integer]] -> c -> Property
prop_map_any_zero = makePropEq (Q.map (Q.any (Q.== 0))) (map (any (== 0)))

prop_all_zero :: Backend c => [Integer] -> c -> Property
prop_all_zero = makePropEq (Q.all (Q.== 0)) (all (== 0))

prop_map_all_zero :: Backend c => [[Integer]] -> c -> Property
prop_map_all_zero = makePropEq (Q.map (Q.all (Q.== 0))) (map (all (== 0)))

prop_sum_integer :: Backend c => [Integer] -> c -> Property
prop_sum_integer = makePropEq Q.sum sum

avgInt :: [Integer] -> Double
avgInt is = (realToFrac $ sum is) / (fromIntegral $ length is)

prop_avg_integer :: Backend c => [Integer] -> c -> Property
prop_avg_integer is conn = (not $ null is) ==> makePropEq Q.avg avgInt is conn

prop_map_sum :: Backend c => [[Integer]] -> c -> Property
prop_map_sum = makePropEq (Q.map Q.sum) (map sum)

prop_map_avg :: Backend c => [[Integer]] -> c -> Property
prop_map_avg is conn = (not $ any null is)
                       ==>
                       makePropEq (Q.map Q.avg) (map avgInt) is conn

prop_map_map_sum :: Backend c => [[[Integer]]] -> c -> Property
prop_map_map_sum = makePropEq (Q.map (Q.map Q.sum)) (map (map sum))

prop_map_map_avg :: Backend c => [[[Integer]]] -> c -> Property
prop_map_map_avg is conn =
    (not $ any (any null) is)
    ==>
    makePropEq (Q.map (Q.map Q.avg)) (map (map avgInt)) is conn

prop_sum_double :: Backend c => [Double] -> c -> Property
prop_sum_double = makePropDouble Q.sum sum

avgDouble :: [Double] -> Double
avgDouble ds = sum ds / (fromIntegral $ length ds)

prop_avg_double :: Backend c => [Double] -> c -> Property
prop_avg_double ds conn = (not $ null ds) ==> makePropDouble Q.avg avgDouble ds conn

prop_concat :: Backend c => [[Integer]] -> c -> Property
prop_concat = makePropEq Q.concat concat

prop_map_concat :: Backend c => [[[Integer]]] -> c -> Property
prop_map_concat = makePropEq (Q.map Q.concat) (map concat)

prop_concatMap :: Backend c => [Integer] -> c -> Property
prop_concatMap = makePropEq (Q.concatMap Q.singleton) (concatMap (: []))

prop_maximum :: Backend c => [Integer] -> c -> Property
prop_maximum = makePropNotNull Q.maximum maximum

prop_minimum :: Backend c => [Integer] -> c -> Property
prop_minimum = makePropNotNull Q.minimum minimum

prop_splitAt :: Backend c => (Integer, [Integer]) -> c -> Property
prop_splitAt = makePropEq (uncurryQ Q.splitAt) (\(a,b) -> splitAt (fromIntegral a) b)

prop_takeWhile :: Backend c => (Integer, [Integer]) -> c -> Property
prop_takeWhile = makePropEq (uncurryQ $ Q.takeWhile . (Q.==))
                          (uncurry  $   takeWhile . (==))

prop_dropWhile :: Backend c => (Integer, [Integer]) -> c -> Property
prop_dropWhile = makePropEq (uncurryQ $ Q.dropWhile . (Q.==))
                          (uncurry  $   dropWhile . (==))

prop_map_takeWhile :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_takeWhile = makePropEq (\z -> Q.map (Q.takeWhile (Q.fst z Q.==)) (Q.snd z))
                              (\z -> map (takeWhile (fst z ==)) (snd z))

prop_map_dropWhile :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_dropWhile = makePropEq (\z -> Q.map (Q.dropWhile (Q.fst z Q.==)) (Q.snd z))
                              (\z -> map (dropWhile (fst z ==)) (snd z))

prop_span :: Backend c => (Integer, [Integer]) -> c -> Property
prop_span = makePropEq (uncurryQ $ Q.span . (Q.==))
                     (uncurry   $   span . (==) . fromIntegral)

prop_map_span :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_span = makePropEq (\z -> Q.map (Q.span ((Q.fst z) Q.==)) (Q.snd z))
                         (\z -> map (span (fst z ==)) (snd z))

prop_break :: Backend c => (Integer, [Integer]) -> c -> Property
prop_break = makePropEq (uncurryQ $ Q.break . (Q.==))
                      (uncurry   $   break . (==) . fromIntegral)

prop_map_break :: Backend c => (Integer, [[Integer]]) -> c -> Property
prop_map_break = makePropEq (\z -> Q.map (Q.break ((Q.fst z) Q.==)) (Q.snd z))
                          (\z -> map (break (fst z ==)) (snd z))

prop_elem :: Backend c => (Integer, [Integer]) -> c -> Property
prop_elem = makePropEq (uncurryQ Q.elem)
                     (uncurry    elem)

prop_notElem :: Backend c => (Integer, [Integer]) -> c -> Property
prop_notElem = makePropEq (uncurryQ Q.notElem)
                        (uncurry    notElem)

prop_lookup :: Backend c => (Integer, [(Integer,Integer)]) -> c -> Property
prop_lookup = makePropEq (uncurryQ Q.lookup)
                       (uncurry    lookup)

prop_zip :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_zip = makePropEq (uncurryQ Q.zip) (uncurry zip)

prop_map_zip :: Backend c => ([Integer], [[Integer]]) -> c -> Property
prop_map_zip = makePropEq (\z -> Q.map (Q.zip $ Q.fst z) $ Q.snd z) (\(x, y) -> map (zip x) y)

prop_zipWith :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_zipWith = makePropEq (uncurryQ $ Q.zipWith (+)) (uncurry $ zipWith (+))

prop_unzip :: Backend c => [(Integer, Integer)] -> c -> Property
prop_unzip = makePropEq Q.unzip unzip

prop_map_unzip :: Backend c => [[(Integer, Integer)]] -> c -> Property
prop_map_unzip = makePropEq (Q.map Q.unzip) (map unzip)

prop_zip3 :: Backend c => ([Integer], [Integer],[Integer]) -> c -> Property
prop_zip3 = makePropEq (\q -> (case Q.view q of (as,bs,cs) -> Q.zip3 as bs cs))
                     (\(as,bs,cs) -> zip3 as bs cs)

prop_zipWith3 :: Backend c => ([Integer], [Integer],[Integer]) -> c -> Property
prop_zipWith3 = makePropEq (\q -> (case Q.view q of (as,bs,cs) -> Q.zipWith3 (\a b c -> a + b + c) as bs cs))
                         (\(as,bs,cs) -> zipWith3 (\a b c -> a + b + c) as bs cs)

prop_unzip3 :: Backend c => [(Integer, Integer, Integer)] -> c -> Property
prop_unzip3 = makePropEq Q.unzip3 unzip3

prop_nub :: Backend c => [Integer] -> c -> Property
prop_nub = makePropEq Q.nub nub

prop_map_nub :: Backend c => [[(Integer, Integer)]] -> c -> Property
prop_map_nub = makePropEq (Q.map Q.nub) (map nub)

-- * Tuples

prop_fst :: Backend c => (Integer, Integer) -> c -> Property
prop_fst = makePropEq Q.fst fst

prop_fst_nested :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_fst_nested = makePropEq Q.fst fst

prop_map_fst :: Backend c => [(Integer, Integer)] -> c -> Property
prop_map_fst = makePropEq (Q.map Q.fst) (map fst)

prop_snd :: Backend c => (Integer, Integer) -> c -> Property
prop_snd = makePropEq Q.snd snd

prop_map_snd :: Backend c => [(Integer, Integer)] -> c -> Property
prop_map_snd = makePropEq (Q.map Q.snd) (map snd)

prop_snd_nested :: Backend c => ([Integer], [Integer]) -> c -> Property
prop_snd_nested = makePropEq Q.snd snd

prop_tup3_1 :: Backend c => (Integer, Integer, Integer) -> c -> Property
prop_tup3_1 = makePropEq (\q -> case Q.view q of (a, _, _) -> a) (\(a, _, _) -> a)

prop_tup3_2 :: Backend c => (Integer, Integer, Integer) -> c -> Property
prop_tup3_2 = makePropEq (\q -> case Q.view q of (_, b, _) -> b) (\(_, b, _) -> b)

prop_tup3_3 :: Backend c => (Integer, Integer, Integer) -> c -> Property
prop_tup3_3 = makePropEq (\q -> case Q.view q of (_, _, c) -> c) (\(_, _, c) -> c)

prop_tup4_2 :: Backend c => (Integer, Integer, Integer, Integer) -> c -> Property
prop_tup4_2 = makePropEq (\q -> case Q.view q of (_, b, _, _) -> b) (\(_, b, _, _) -> b)

prop_tup4_4 :: Backend c => (Integer, Integer, Integer, Integer) -> c -> Property
prop_tup4_4 = makePropEq (\q -> case Q.view q of (_, _, _, d) -> d) (\(_, _, _, d) -> d)

prop_tup3_nested :: Backend c => (Integer, [Integer], Integer) -> c -> Property
prop_tup3_nested = makePropEq (\q -> case Q.view q of (_, b, _) -> b) (\(_, b, _) -> b)

prop_tup4_tup3 :: Backend c => (Integer, Integer, Integer, Integer) -> c -> Property
prop_tup4_tup3 = makePropEq (\q -> case Q.view q of (a, b, _, d) -> Q.tup3 a b d)
                          (\(a, b, _, d) -> (a, b, d))

-- * Numerics

prop_add_integer :: Backend c => (Integer,Integer) -> c -> Property
prop_add_integer = makePropEq (uncurryQ (+)) (uncurry (+))

prop_add_double :: Backend c => (Double,Double) -> c -> Property
prop_add_double = makePropDouble (uncurryQ (+)) (uncurry (+))

prop_mul_integer :: Backend c => (Integer,Integer) -> c -> Property
prop_mul_integer = makePropEq (uncurryQ (*)) (uncurry (*))

prop_mul_double :: Backend c => (Double,Double) -> c -> Property
prop_mul_double = makePropDouble (uncurryQ (*)) (uncurry (*))

prop_div_double :: Backend c => (Double,Double) -> c -> Property
prop_div_double (x,y) conn =
    y /= 0
    ==>
    makePropDouble (uncurryQ (/)) (uncurry (/)) (x,y) conn

prop_integer_to_double :: Backend c => Integer -> c -> Property
prop_integer_to_double = makePropDouble Q.integerToDouble fromInteger

prop_integer_to_double_arith :: Backend c => (Integer, Double) -> c -> Property
prop_integer_to_double_arith = makePropDouble (\x -> (Q.integerToDouble (Q.fst x)) + (Q.snd x))
                                              (\(i, d) -> fromInteger i + d)

prop_map_integer_to_double :: Backend c => [Integer] -> c -> Property
prop_map_integer_to_double = makePropDoubles (Q.map Q.integerToDouble) (map fromInteger)

prop_abs_integer :: Backend c => Integer -> c -> Property
prop_abs_integer = makePropEq Q.abs abs

prop_abs_double :: Backend c => Double -> c -> Property
prop_abs_double = makePropDouble Q.abs abs

prop_signum_integer :: Backend c => Integer -> c -> Property
prop_signum_integer = makePropEq Q.signum signum

prop_signum_double :: Backend c => Double -> c -> Property
prop_signum_double = makePropDouble Q.signum signum

prop_negate_integer :: Backend c => Integer -> c -> Property
prop_negate_integer = makePropEq Q.negate negate

prop_negate_double :: Backend c => Double -> c -> Property
prop_negate_double = makePropDouble Q.negate negate

prop_trig_sin :: Backend c => Double -> c -> Property
prop_trig_sin = makePropDouble Q.sin sin

prop_trig_cos :: Backend c => Double -> c -> Property
prop_trig_cos = makePropDouble Q.cos cos

prop_trig_tan :: Backend c => Double -> c -> Property
prop_trig_tan = makePropDouble Q.tan tan

prop_exp :: Backend c => Double -> c -> Property
prop_exp = makePropDouble Q.exp exp

prop_log :: Backend c => Double -> c -> Property
prop_log d conn = d > 0 ==> makePropDouble Q.log log d conn

prop_sqrt :: Backend c => Double -> c -> Property
prop_sqrt d conn = d > 0 ==> makePropDouble Q.sqrt sqrt d conn

arc :: Double -> Bool
arc d = d >= -1 && d <= 1

prop_trig_asin :: Backend c => Double -> c -> Property
prop_trig_asin d conn = arc d ==>  makePropDouble Q.asin asin d conn

prop_trig_acos :: Backend c => Double -> c -> Property
prop_trig_acos d conn = arc d ==> makePropDouble Q.acos acos d conn

prop_trig_atan :: Backend c => Double -> c -> Property
prop_trig_atan = makePropDouble Q.atan atan

prop_number :: Backend c => [Integer] -> c -> Property
prop_number = makePropEq (Q.map Q.snd . Q.number) (\xs -> map snd $ zip xs [1..])

prop_map_number :: Backend c => [[Integer]] -> c -> Property
prop_map_number = makePropEq (Q.map (Q.map Q.snd . Q.number))
                            (map (\xs -> map snd $ zip xs [1..]))

prop_transpose :: Backend c => [[Integer]] -> c -> Property
prop_transpose = makePropEq Q.transpose transpose

{-
prop_map_transpose :: Backend c => [[[Integer]]] -> c -> Property
prop_map_transpose xss =
    (all (not . null) (xss :: [[[Integer]]])
    &&
    and (map (all (not . null)) xss))
    ==> makePropEq (Q.map Q.transpose) (map transpose)
-}

reshape :: Int -> [a] -> [[a]]
reshape _ [] = []
reshape i xs = take i xs : reshape i (drop i xs)

prop_reshape :: Backend c => [Integer] -> c -> Property
prop_reshape = makePropEq (Q.reshape 5) (reshape 5)

prop_reshape2 :: Backend c => [Integer] -> c -> Property
prop_reshape2 = makePropEq (Q.reshape 2) (reshape 2)

prop_map_reshape :: Backend c => [[Integer]] -> c -> Property
prop_map_reshape = makePropEq (Q.map (Q.reshape 8)) (map (reshape 8))

prop_map_reshape2 :: Backend c => [[Integer]] -> c -> Property
prop_map_reshape2 = makePropEq (Q.map (Q.reshape 2)) (map (reshape 2))

prop_map_trig_sin :: Backend c => [Double] -> c -> Property
prop_map_trig_sin = makePropDoubles (Q.map Q.sin) (map sin)

prop_map_trig_cos :: Backend c => [Double] -> c -> Property
prop_map_trig_cos = makePropDoubles (Q.map Q.cos) (map cos)

prop_map_trig_tan :: Backend c => [Double] -> c -> Property
prop_map_trig_tan = makePropDoubles (Q.map Q.tan) (map tan)

prop_map_trig_asin :: Backend c => [Double] -> c -> Property
prop_map_trig_asin ds conn = all arc ds
                             ==>
                             makePropDoubles (Q.map Q.asin) (map asin) ds conn

prop_map_trig_acos :: Backend c => [Double] -> c -> Property
prop_map_trig_acos ds conn = all arc ds
                             ==>
                             makePropDoubles (Q.map Q.acos) (map acos) ds conn

prop_map_trig_atan :: Backend c => [Double] -> c -> Property
prop_map_trig_atan = makePropDoubles (Q.map Q.atan) (map atan)

prop_map_exp :: Backend c => [Double] -> c -> Property
prop_map_exp = makePropDoubles (Q.map Q.exp) (map exp)

prop_map_log :: Backend c => [Double] -> c -> Property
prop_map_log ds conn = all (> 0) ds
                       ==>
                       makePropDoubles (Q.map Q.log) (map log) ds conn

prop_map_sqrt :: Backend c => [Double] -> c -> Property
prop_map_sqrt ds conn = all (> 0) ds
                        ==>
                        makePropDoubles (Q.map Q.sqrt) (map sqrt) ds conn

hnegative_sum :: Backend c => c -> Assertion
hnegative_sum conn = makeEqAssertion "hnegative_sum" (Q.sum (Q.toQ xs)) (sum xs) conn
  where
    xs :: [Integer]
    xs = [-1, -4, -5, 2]

hnegative_map_sum :: Backend c => c -> Assertion
hnegative_map_sum conn = makeEqAssertion "hnegative_map_sum"
                                         (Q.map Q.sum (Q.toQ xss))
                                         (map sum xss)
                                         conn
  where
    xss :: [[Integer]]
    xss = [[10, 20, 30], [-10, -20, -30], [], [0]]

hmap_transpose :: Backend c => c -> Assertion
hmap_transpose conn = makeEqAssertion "hmap_transpose"
                                      (Q.map Q.transpose (Q.toQ xss))
                                      res
                                      conn
  where
    xss :: [[[Integer]]]
    xss = [ [ [10, 20, 30]
            , [40, 50, 60]]
          , [ [100, 200]
            , [300, 400]
            , [500, 600]]
          ]

    res :: [[[Integer]]]
    res = [ [ [10, 40]
            , [20, 50]
            , [30, 60]
            ]
          , [ [100, 300, 500]
            , [200, 400, 600]
            ]
          ]