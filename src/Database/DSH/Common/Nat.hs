{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Common.Nat where

import           Data.Aeson
import           Data.List.NonEmpty             (NonEmpty ((:|)))
import qualified Data.List.NonEmpty             as N
import           Data.Maybe

import           Database.DSH.Common.Impossible

-- | Natural numbers that encode lifting levels
data Nat = Zero | Succ Nat deriving (Show, Eq)

instance Ord Nat where
    Zero    <= Succ _  = True
    Succ n1 <= Succ n2 = n1 <= n2
    _       <= _       = False

(.-) :: Nat -> Nat -> Maybe Nat
n1      .- Zero    = Just n1
Succ n1 .- Succ n2 = n1 .- n2
Zero    .- Succ _  = Nothing

intFromNat :: Nat -> Int
intFromNat Zero     = 0
intFromNat (Succ n) = 1 + intFromNat n

--------------------------------------------------------------------------------

-- | Indexes of tuple fields
data TupleIndex = First | Next TupleIndex deriving (Show, Eq, Ord)

instance ToJSON TupleIndex where
    toJSON = toJSON . tupleIndex

instance FromJSON TupleIndex where
    parseJSON o = intIndex <$> parseJSON o

tupleIndex :: TupleIndex -> Int
tupleIndex First    = 1
tupleIndex (Next f) = 1 + tupleIndex f

intIndex :: Int -> TupleIndex
intIndex i
    | i < 1     = $impossible
    | i > 1     = Next $ (intIndex $ i - 1)
    | otherwise = First

(-.) :: TupleIndex -> TupleIndex -> Maybe TupleIndex
Next x -. First  = Just x
Next x -. Next y = x -. y
_      -. _      = Nothing

instance Num TupleIndex where
    First  + y = Next y
    Next x + y = Next $ x + y

    First  * y = y
    Next x * y = y + x * y

    abs x = x

    x - y = fromMaybe (error "tupleindex substraction") (x -. y)

    signum First = First
    signum (Next _) = First

    fromInteger = intIndex . fromIntegral

instance Enum TupleIndex where
    toEnum i | i > 0 = intIndex i
             | otherwise = error "toEnum: negative or zero TupleIndex"

    fromEnum = tupleIndex

-- | Returns the (one-based) list element denoted by a tuple index.
safeIndex :: TupleIndex -> [a] -> Maybe a
safeIndex First    (x:_)  = Just x
safeIndex (Next i) (_:xs) = safeIndex i xs
safeIndex _        _      = Nothing

-- | Returns the (one-based) list element denoted by a tuple index.
safeIndexN :: TupleIndex -> NonEmpty a -> Maybe a
safeIndexN First xs           = Just $ N.head xs
safeIndexN (Next i) (_ :| xs) = safeIndex i xs
