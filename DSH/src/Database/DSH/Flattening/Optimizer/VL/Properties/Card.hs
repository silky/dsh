-- FIXME complete rules

module Optimizer.VL.Properties.Card where

import Debug.Trace
  
import Control.Applicative

import Database.Algebra.VL.Data
  
import Optimizer.VL.Properties.Types
import Optimizer.VL.Properties.Common

unp :: Show a => VectorProp a -> Either String a
unp = unpack "Properties.Card"

inferCardOneNullOp :: NullOp -> Either String (VectorProp Bool)
inferCardOneNullOp op =
  case op of
    SingletonDescr                -> Right $ VProp True
    ConstructLiteralTable _ rows  -> Right $ VProp $ length rows == 1
    ConstructLiteralValue _ _     -> Right $ VProp True
    TableRef              _ _ _   -> Right $ VProp False

inferCardOneUnOp :: VectorProp Bool -> UnOp -> Either String (VectorProp Bool)
inferCardOneUnOp c op = 
  case op of
    Unique -> Right c
    UniqueL -> Right c
    NotPrim -> Right c
    NotVec -> Right c
    LengthA -> Right $ VProp True
    DescToRename -> Right c
    ToDescr -> Right c
    Segment -> Right c
    VecSum _ -> Right $ VProp True
    VecMin -> Right $ VProp True
    VecMinL -> Right c
    VecMax -> Right $ VProp True
    VecMaxL -> Right c
    ProjectL _ -> Right c
    ProjectA _ -> Right c
    IntegerToDoubleA -> Right c
    IntegerToDoubleL -> Right c
    ReverseA -> unp c >>= (\uc -> return $ VPropPair uc uc)
    ReverseL -> unp c >>= (\uc -> return $ VPropPair uc uc)
    FalsePositions -> Right c
    R1 -> 
      case c of
        VProp _           -> Left "Properties.Card: not a pair/triple"
        VPropPair b _     -> Right $ VProp b
        VPropTriple b _ _ -> Right $ VProp b
    R2 ->
      case c of
        VProp _           -> Left "Properties.Card: not a pair/triple"
        VPropPair _ b     -> Right $ VProp b
        VPropTriple _ b _ -> Right $ VProp b
    R3 ->
      case c of
        VPropTriple _ _ b -> Right $ VProp b
        _                 -> Left "Properties.Card: not a triple"

inferCardOneBinOp :: VectorProp Bool -> VectorProp Bool -> BinOp -> Either String (VectorProp Bool)
inferCardOneBinOp c1 c2 op =
  case op of
    GroupBy -> return $ VPropTriple False False False
    SortWith -> return $ VPropPair False False
    LengthSeg -> return $ VProp False
    DistPrim -> return $ VProp False
    DistDesc -> return $ VProp False
    DistLift -> return $ VProp False
    PropRename -> return $ VProp False
    PropFilter -> return $ VProp False
    PropReorder -> return $ VProp False
    -- FIXME more precisely: empty(left) and card1(right) or card1(left) and empty(right)
    Append -> Right $ VProp False
    RestrictVec -> Right $ VProp False
    CompExpr2 _ -> VProp <$> ((||) <$> unp c1 <*> unp c2)
    CompExpr2L _ -> VProp <$> ((||) <$> unp c1 <*> unp c2)
    VecSumL -> Right c1
    SelectPos _ -> Right c1
    SelectPosL _ -> Right c1
    PairA -> VProp <$> ((||) <$> unp c1 <*> unp c2)
    PairL -> VProp <$> ((||) <$> unp c1 <*> unp c2)
    ZipL -> do
      c <- (||) <$> unp c1 <*> unp c2
      return $ VPropTriple c c c
      
inferCardOneTerOp :: VectorProp Bool -> VectorProp Bool -> VectorProp Bool -> TerOp -> Either String (VectorProp Bool)
inferCardOneTerOp _ _ _ op =
  case op of
    CombineVec -> return $ VPropTriple False False False
