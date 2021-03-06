{-# LANGUAGE TemplateHaskell #-}

-- FIXME introduce consistency checks for schema inference
module Database.DSH.SL.Opt.Properties.VectorType where

import           Control.Monad
import qualified Data.List.NonEmpty as N

import           Database.DSH.SL.Opt.Properties.Types
import           Database.DSH.Common.Lang
import           Database.DSH.Common.VectorLang

import           Database.DSH.SL.Lang

{- Implement more checks: check the input types for correctness -}

vectorWidth :: VectorProp VectorType -> PType
vectorWidth (VProp (VTDataVec w))  = w
vectorWidth _                      = error "vectorWidth: non-VTDataVec input"

inferVectorTypeNullOp :: NullOp -> Either String (VectorProp VectorType)
inferVectorTypeNullOp op =
  case op of
    Lit (ty, _)          -> Right $ VProp $ VTDataVec ty
    TableRef (_, schema) -> Right $ VProp $ VTDataVec $ PTupleT $ N.toList $ fmap (PScalarT . snd) tableCols

unpack :: VectorProp VectorType -> Either String VectorType
unpack (VProp s) = Right s
unpack _         = Left "Input is not a single vector property"

inferVectorTypeUnOp :: VectorProp VectorType -> UnOp -> Either String (VectorProp VectorType)
inferVectorTypeUnOp s op =
  case op of
    WinFun _ -> do
        VTDataVec w <- unpack s
        return $ VProp $ VTDataVec $ w + 1
    Unique -> VProp <$> unpack s
    UnboxKey -> Right $ VProp $ VTNA
    Segment -> VProp <$> unpack s
    Unsegment -> VProp <$> unpack s
    Reverse -> liftM2 VPropPair (unpack s) (Right VTNA)
    R1 ->
      case s of
        VPropPair s1 _ -> Right $ VProp s1
        VPropTriple s1 _ _ -> Right $ VProp s1
        _ -> Left "Input of R1 is not a tuple"
    R2 ->
      case s of
        VPropPair _ s2 -> Right $ VProp s2
        VPropTriple _ s2 _ -> Right $ VProp s2
        _ -> Left "Input of R2 is not a tuple"
    R3 ->
      case s of
        VPropTriple s3 _ _ -> Right $ VProp s3
        _ -> Left "Input of R3 is not a tuple"

    Project valProjs -> Right $ VProp $ VTDataVec $ length valProjs

    Select _ -> VPropPair <$> unpack s <*> (Right VTNA)
    Sort _  -> liftM2 VPropPair (unpack s) (Right VTNA)

    Group es ->
      case s of
        VProp t@(VTDataVec _) ->
          Right $ VPropTriple (VTDataVec $ length es) t VTNA
        _                                                    ->
          Left "Input of GroupS is not a value vector"
    GroupAggr (g, as) -> Right $ VProp $ VTDataVec (length g + N.length as)
    Number -> do
        VTDataVec w <- unpack s
        return $ VProp $ VTDataVec (w + 1)

reqValVectors :: VectorProp VectorType
                 -> VectorProp VectorType
                 -> (Int -> Int -> VectorProp VectorType)
                 -> String
                 -> Either String (VectorProp VectorType)
reqValVectors (VProp (VTDataVec w1)) (VProp (VTDataVec w2)) f _ =
  Right $ f w1 w2
reqValVectors _ _ _ e =
  Left $ "Inputs of " ++ e ++ " are not VTDataVecs"

inferVectorTypeBinOp :: VectorProp VectorType -> VectorProp VectorType -> BinOp -> Either String (VectorProp VectorType)
inferVectorTypeBinOp s1 s2 op =
  case op of
    Fold _ -> return $ VProp $ VTDataVec 1

    ReplicateNest -> do
        VTDataVec w1 <- unpack s1
        VTDataVec w2 <- unpack s2
        return $ VPropPair (VTDataVec $ w1 + w2) VTNA
    ReplicateScalar -> do
        VTDataVec w1 <- unpack s1
        VTDataVec w2 <- unpack s2
        return $ VPropPair (VTDataVec $ w1 + w2) VTNA

    AppRep -> liftM2 VPropPair (unpack s2) (Right VTNA)
    AppSort -> liftM2 VPropPair (unpack s2) (Right VTNA)
    AppFilter -> liftM2 VPropPair (unpack s2) (Right VTNA)
    AppKey -> liftM2 VPropPair (unpack s2) (Right VTNA)
    Append ->
      case (s1, s2) of
        (VProp (VTDataVec w1), VProp (VTDataVec w2)) | w1 == w2 ->
          Right $ VPropTriple (VTDataVec w1) VTNA VTNA
        (VProp (VTDataVec w1), VProp (VTDataVec w2)) ->
          Left $ "Inputs of Append do not have the same width " ++ (show w1) ++ " " ++ (show w2)
        v ->
          Left $ "Input of Append is not a VTDataVec " ++ (show v)

    Align ->
      case (s1, s2) of
        (VProp (VTDataVec w1), VProp (VTDataVec w2)) -> Right $ VProp $ VTDataVec $ w1 + w2
        _                                                -> Left "Inputs of Align are not VTDataVecs"
    Zip -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (VTDataVec $ w1 + w2) VTNA VTNA) "ZipL"
    CartProduct -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (VTDataVec $ w1 + w2) VTNA VTNA) "CartProductS"
    ReplicateVector -> reqValVectors s1 s2 (\w1 _ -> VPropPair (VTDataVec w1 ) VTNA) "ReplicateVector"
    UnboxSng -> reqValVectors s1 s2 (\w1 w2 -> VPropPair (VTDataVec $ w1 + w2) VTNA) "UnboxSng"
    UnboxDefault _ -> reqValVectors s1 s2 (\w1 w2 -> VProp (VTDataVec $ w1 + w2) VTNA) "UnboxDefault"
    ThetaJoin _ -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (VTDataVec $ w1 + w2) VTNA VTNA) "ThetaJoinS"
    NestJoin _ -> reqValVectors s1 s2 (\w1 w2 -> VPropTriple (VTDataVec $ w1 + w2) VTNA VTNA) "NestJoinS"
    GroupJoin (_, as) -> do
        VTDataVec w <- unpack s1
        return $ VProp $ VTDataVec (w + length (getNE as))
    SemiJoin _ -> liftM2 VPropPair (unpack s1) (Right VTNA)
    AntiJoin _ -> liftM2 VPropPair (unpack s1) (Right VTNA)

inferVectorTypeTerOp :: VectorProp VectorType -> VectorProp VectorType -> VectorProp VectorType -> TerOp -> Either String (VectorProp VectorType)
inferVectorTypeTerOp _ s2 s3 op =
  case op of
    Combine ->
      case (s2, s3) of
        (VProp (VTDataVec w1), VProp (VTDataVec w2)) | w1 == w2 ->
          Right $ VPropTriple (VTDataVec w1) VTNA VTNA
        (VProp (VTDataVec _), VProp (VTDataVec _))              ->
          Left $ "Inputs of CombineVec do not have the same width"
        _                                                           ->
          Left $ "Inputs of CombineVec are not VTDataVecs/DescrVectors " ++ (show (s2, s3))
