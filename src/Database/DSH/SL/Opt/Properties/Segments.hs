{-# LANGUAGE MonadComprehensions #-}

-- | Statically infer information about the segments of a vector. Currently we
-- can determine wether the vector is 'flat' (i.e. has only the unit segment) or
-- whether it is a proper segmented vector.
module Database.DSH.SL.Opt.Properties.Segments where

import Control.Monad.Except

import Database.DSH.SL.Lang
import Database.DSH.Common.VectorLang

import Database.DSH.SL.Opt.Properties.Types
import Database.DSH.SL.Opt.Properties.Common

unp :: Show a => VectorProp a -> Either String a
unp = unpack "Properties.Segments"

inferSegmentsNullOp :: NullOp -> Either String (VectorProp SegP)
inferSegmentsNullOp op =
  case op of
    -- Check wether all rows are in the unit segment
    Lit (_, seg) ->
        case seg of
            UnitSeg _ -> pure $ VProp UnitSegP
            Segs _    -> pure $ VProp SegdP
    TableRef _    -> pure $ VProp UnitSegP

flatInputs :: SegP -> SegP -> Either String SegP
flatInputs UnitSegP UnitSegP = pure UnitSegP
flatInputs SegdP    SegdP    = pure SegdP
flatInputs SegNAP   _        = throwError "Properties.Segments: unexpected SegNAP input"
flatInputs _        SegNAP   = throwError "Properties.Segments: unexpected SegNAP input"
flatInputs s1       s2       = throwError $ "Properties.Segments: inconsistent inputs " ++ show s1 ++ " " ++ show s2

inferSegmentsUnOp :: VectorProp SegP -> UnOp r e -> Either String (VectorProp SegP)
inferSegmentsUnOp c op =
  case op of
    Unique     -> pure c
    WinFun _    -> pure c
    Segment     -> pure $ VProp SegdP
    Unsegment   -> pure $ VProp UnitSegP
    Project _   -> pure c
    Reverse    -> [ VPropPair f SegNAP | f <- unp c ]
    Select _    -> [ VPropPair f SegNAP | f <- unp c ]
    Sort _     -> [ VPropPair f SegNAP | f <- unp c ]
    Group _    -> [ VPropTriple f SegdP SegNAP | f <- unp c ]
    GroupAggr _ -> pure c
    Number     -> pure c
    Fold _      -> pure $ VProp SegdP
    R1          ->
      case c of
        VProp _           -> throwError "Properties.Segments: not a pair/triple"
        VPropPair b _     -> pure $ VProp b
        VPropTriple b _ _ -> pure $ VProp b
    R2          ->
      case c of
        VProp _           -> throwError "Properties.Segments: not a pair/triple"
        VPropPair _ b     -> pure $ VProp b
        VPropTriple _ b _ -> pure $ VProp b
    R3          ->
      case c of
        VPropTriple _ _ b -> pure $ VProp b
        _                 -> throwError "Properties.Segments: not a triple"

inferSegmentsBinOp :: VectorProp SegP -> VectorProp SegP -> BinOp e -> Either String (VectorProp SegP)
inferSegmentsBinOp c1 c2 op =
  case op of
    ReplicateNest   -> pure $ VPropPair SegdP SegNAP
    ReplicateScalar -> [ VPropPair f SegNAP | f <- unp c2 ]
    AppKey          -> pure $ VProp SegdP
    AppSort         -> pure $ VPropPair SegdP SegNAP
    AppFilter       -> pure $ VPropPair SegdP SegNAP
    AppRep          -> pure $ VPropPair SegdP SegNAP
    UnboxSng        -> [ VPropPair f SegNAP | f <- unp c1 ]
    UnboxDefault _  -> [ VPropPair f SegNAP | f <- unp c1 ]
    Append          -> join [ VPropTriple <$> flatInputs f1 f2 <*> pure SegNAP <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]
    Align           -> join [ VProp <$> flatInputs f1 f2 | f1 <- unp c1, f2 <- unp c2 ]
    MergeSeg        -> VProp <$> unp c1 
    CartProduct     -> join [ VPropTriple <$> flatInputs f1 f2 <*> pure SegNAP <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]
    ReplicateVector -> pure $ VPropPair SegdP SegNAP
    ThetaJoin  _    -> join [ VPropTriple <$> flatInputs f1 f2 <*> pure SegNAP <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]
    NestJoin  _     -> pure $ VPropTriple SegdP SegNAP SegNAP
    GroupJoin _     -> join [ VProp <$> flatInputs f1 f2 | f1 <- unp c1, f2 <- unp c2 ]
    SemiJoin _      -> join [ VPropPair <$> flatInputs f1 f2 <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]
    AntiJoin _      -> join [ VPropPair <$> flatInputs f1 f2 <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]
    Zip             -> join [ VPropTriple <$> flatInputs f1 f2 <*> pure SegNAP <*> pure SegNAP | f1 <- unp c1, f2 <- unp c2 ]

inferSegmentsTerOp :: VectorProp SegP -> VectorProp SegP -> VectorProp SegP -> TerOp -> Either String (VectorProp SegP)
inferSegmentsTerOp c1 _ _ op =
  case op of
    -- All three input vectors need to have the same segment structure.
    Combine -> [ VPropTriple s1 SegNAP SegNAP | s1 <- unp c1 ]
