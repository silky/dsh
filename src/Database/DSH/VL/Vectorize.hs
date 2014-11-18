{-# LANGUAGE TemplateHaskell  #-}
{-# LANGUAGE ParallelListComp #-}

-- | Vectorising constructor functions that implement FKL primitives
-- using VL operators.
module Database.DSH.VL.Vectorize where

import           Debug.Trace

import           Control.Applicative
import qualified Data.List                     as List
import           Prelude                       hiding (reverse, zip)
import qualified Prelude                       as P

import           Database.Algebra.Dag.Build

import qualified Database.DSH.Common.Lang      as L
import           Database.DSH.Common.Nat
import           Database.DSH.Common.QueryPlan
import           Database.DSH.Common.Type
import           Database.DSH.Impossible
import           Database.DSH.VL.Lang          (AggrFun (..), Expr (..), VL (),
                                                VLVal (..))
import           Database.DSH.VL.Primitives
import           Database.DSH.VL.Vector

--------------------------------------------------------------------------------
-- Construction of not-lifted primitives

zip ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
zip (VShape q1 lyt1) (VShape q2 lyt2) = do
    q' <- vlZip q1 q2
    return $ VShape q' $ zipLayout lyt1 lyt2
zip _ _ = $impossible

cartProduct :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
cartProduct (VShape q1 lyt1) (VShape q2 lyt2) = do
    (q', p1, p2) <- vlCartProduct q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ VShape q' $ zipLayout lyt1' lyt2'
cartProduct _ _ = $impossible

nestProduct :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
nestProduct (VShape q1 lyt1) (VShape q2 lyt2) = do
  (q', p1, p2) <- vlNestProduct q1 q2
  lyt1'        <- chainReorder p1 lyt1
  lyt2'        <- chainReorder p2 lyt2
  return $ VShape q1 (LTuple [lyt1, LNest q' (zipLayout lyt1' lyt2')])
nestProduct _ _ = $impossible

thetaJoin :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
thetaJoin joinPred (VShape q1 lyt1) (VShape q2 lyt2) = do
    (q', p1, p2) <- vlThetaJoin joinPred q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ VShape q' $ zipLayout lyt1' lyt2'
thetaJoin _ _ _ = $impossible

nestJoin :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
nestJoin joinPred (VShape q1 lyt1) (VShape q2 lyt2) = do
    (q', p1, p2) <- vlNestJoin joinPred q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ VShape q1 (LTuple [lyt1, LNest q' (zipLayout lyt1' lyt2')])
nestJoin _ _ _ = $impossible

semiJoin :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
semiJoin joinPred (VShape q1 lyt1) (VShape q2 _) = do
    (qj, r) <- vlSemiJoin joinPred q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ VShape qj lyt1'
semiJoin _ _ _ = $impossible

antiJoin :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
antiJoin joinPred (VShape q1 lyt1) (VShape q2 _) = do
    (qj, r) <- vlAntiJoin joinPred q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ VShape qj lyt1'
antiJoin _ _ _ = $impossible

nub ::  Shape VLDVec -> Build VL (Shape VLDVec)
nub (VShape q lyt) = VShape <$> vlUniqueS q <*> pure lyt
nub _ = $impossible

number ::  Shape VLDVec -> Build VL (Shape VLDVec)
number (VShape q lyt) =
    VShape <$> vlNumber q
                <*> (pure $ zipLayout lyt (LCol 1))
number _ = $impossible

init ::  Shape VLDVec -> Build VL (Shape VLDVec)
init (VShape q lyt) = do
    i          <- vlAggr AggrCount q
    (q', r, _) <- vlSelectPos q (L.SBRelOp L.Lt) i
    lyt'       <- chainRenameFilter r lyt
    return $ VShape q' lyt'
init _ = $impossible

last ::  Shape VLDVec -> Build VL (Shape VLDVec)
last (VShape qs lyt@(LNest _ _)) = do
    i              <- vlAggr AggrCount qs
    (q, r, _)      <- vlSelectPos qs (L.SBRelOp L.Eq) i
    (LNest qr lyt') <- chainRenameFilter r lyt
    re             <- vlUnboxRename q
    renameOuter re $ VShape qr lyt'
last (VShape qs lyt) = do
    i         <- vlAggr AggrCount qs
    (q, r, _) <- vlSelectPos qs (L.SBRelOp L.Eq) i
    lyt'      <- chainRenameFilter r lyt
    return $ SShape q lyt'
last _ = $impossible

index ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
index (VShape qs (LNest qi lyti)) (SShape i _) = do
    one       <- literal intT (VLInt 1)
    i'        <- vlBinExpr (L.SBNumOp L.Add) i one
    -- Use the unboxing rename vector
    (_, _, r) <- vlSelectPos qs (L.SBRelOp L.Eq) i'
    (qu, ri)  <- vlUnboxNested r qi
    lyti'     <- chainRenameFilter ri lyti
    return $ VShape qu lyti'
index (VShape qs lyt) (SShape i _) = do
    one       <- literal intT (VLInt 1)
    i'        <- vlBinExpr (L.SBNumOp L.Add) i one
    (q, r, _) <- vlSelectPos qs (L.SBRelOp L.Eq) i'
    lyt'      <- chainRenameFilter r lyt
    return $ SShape q lyt'
index _ _ = $impossible

append ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
append = appendVec

-- FIXME looks fishy, there should be an unboxing join.
the ::  Shape VLDVec -> Build VL (Shape VLDVec)
the (VShape d lyt@(LNest _ _)) = do
    (_, prop, _)   <- vlSelectPos1 d (L.SBRelOp L.Eq) 1
    (LNest q' lyt') <- chainRenameFilter prop lyt
    return $ VShape q' lyt'
the (VShape d lyt) = do
    (q', prop, _) <- vlSelectPos1 d (L.SBRelOp L.Eq) 1
    lyt'          <- chainRenameFilter prop lyt
    return $ SShape q' lyt'
the _ = $impossible

reverse ::  Shape VLDVec -> Build VL (Shape VLDVec)
reverse (VShape d lyt) = do
    (d', p) <- vlReverse d
    lyt'    <- chainReorder p lyt
    return (VShape d' lyt')
reverse _ = $impossible

tail ::  Shape VLDVec -> Build VL (Shape VLDVec)
tail (VShape d lyt) = do
    p          <- literal intT (VLInt 1)
    (q', r, _) <- vlSelectPos d (L.SBRelOp L.Gt) p
    lyt'       <- chainRenameFilter r lyt
    return $ VShape q' lyt'
tail _ = $impossible

sort :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
sort (VShape q1 lyt1) (VShape q2 lyt2) = do
    let leftWidth  = columnsInLayout lyt1
        rightWidth = columnsInLayout lyt2

        sortExprs = map Column [leftWidth+1..leftWidth+rightWidth]

    -- Sort by all columns from the right vector
    (sortedVec, propVec) <- vlSortS sortExprs =<< vlAlign q1 q2

    -- After sorting, discard the sorting criteria columns from the
    -- right vector
    resVec               <- vlProject (map Column [1..leftWidth]) sortedVec
    lyt1'  <- chainReorder propVec lyt1
    return $ VShape resVec lyt1'
sort _e1 _e2 = $impossible

-- | The right input contains the grouping columns.
group ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
group (VShape q1 lyt1) (VShape q2 lyt2) = do
    let leftWidth  = columnsInLayout lyt1
        rightWidth = columnsInLayout lyt2

        groupExprs = map Column [leftWidth+1..leftWidth+rightWidth]

    (outerVec, innerVec, propVec) <- vlGroupS groupExprs =<< vlAlign q1 q2

    -- Discard the grouping columns in the inner vector
    innerVec' <- vlProject (map Column [1..leftWidth]) innerVec

    lyt1'     <- chainReorder propVec lyt1
    return $ VShape outerVec (LTuple [lyt2, LNest innerVec' lyt1'])
group _e1 _e2 = $impossible

length_ ::  Shape VLDVec -> Build VL (Shape VLDVec)
length_ q = do
    v' <- outer q
    v  <- vlAggr AggrCount v'
    return $ SShape v (LCol 1)

cons ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
cons q1@(SShape _ _) q2@(VShape _ _) = do
    n <- singletonAtom q1
    appendVec n q2
cons q1 q2 = do
    n <- singletonVec q1
    appendVec n q2

restrict ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
restrict(VShape q1 lyt) (VShape q2 (LCol 1)) = do
    -- The right input vector has only one boolean column which
    -- defines wether the tuple at the same position in the left input
    -- is preserved.
    let leftWidth = columnsInLayout lyt
        predicate = Column $ leftWidth + 1

    -- Filter the vector according to the boolean column
    (filteredVec, renameVec) <- vlSelect predicate =<< vlAlign q1 q2

    -- After the selection, discard the boolean column from the right
    resVec                   <- vlProject (map Column [1..leftWidth]) filteredVec
    
    -- Filter any inner vectors
    lyt'                     <- chainRenameFilter renameVec lyt
    return $ VShape resVec lyt'
restrict _e1 _e2 = $impossible

combine ::  Shape VLDVec -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
combine (VShape qb (LCol 1)) (VShape q1 lyt1) (VShape q2 lyt2) = do
    (v, p1, p2) <- vlCombine qb q1 q2
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    lyt'        <- appendLayout lyt1' lyt2'
    return $ VShape v lyt'
combine l1 l2 l3 = trace (show l1 ++ " " ++ show l2 ++ " " ++ show l3) $ $impossible

-- | Distribute a single value in vector 'q2' over an arbitrary shape.
distSingleton :: Shape VLDVec -> VLDVec -> Layout VLDVec -> Build VL (Shape VLDVec)
distSingleton shape1 q2 lyt2 = do
    let (shapeCon, q1, lyt1) = unwrapShape shape1

        leftWidth  = columnsInLayout lyt1
        rightWidth = columnsInLayout lyt2
        proj       = map Column [leftWidth+1..leftWidth+rightWidth]

    (prodVec, _, propVec) <- q1 `vlCartProduct` q2
    resVec                <- vlProject proj prodVec

    lyt'                  <- chainReorder propVec lyt2
    return $ shapeCon resVec lyt'

dist ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
-- Distributing a single value is implemented using a cartesian
-- product. After the product, we discard columns from the vector that
-- we distributed over. Vectors are swapped because CartProduct uses
-- the descriptor of its left input and that is what we want.
dist (SShape q lyt) v = distSingleton v q lyt
dist (VShape q lyt) (VShape qo lyto) = do
    let leftWidth  = columnsInLayout lyto
        rightWidth = columnsInLayout lyt
        innerProj  = map Column [leftWidth+1..leftWidth+rightWidth]

    (prodVec, _, propVec) <- vlNestProduct qo q
    innerVec              <- vlProject innerProj prodVec

    -- The outer vector does not have columns, it only describes the
    -- shape.
    outerVec              <- vlProject [] qo
    
    -- Replicate any inner vectors
    lyt'                  <- chainReorder propVec lyt

    return $ VShape outerVec (LNest innerVec lyt')
dist _ _ = $impossible

aggr :: (Expr -> AggrFun) -> Shape VLDVec -> Build VL (Shape VLDVec)
aggr afun (VShape q (LCol 1)) =
    SShape <$> vlAggr (afun (Column 1)) q <*> (pure $ LCol 1)
aggr _ _ = $impossible

ifList ::  Shape VLDVec -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
ifList (SShape qb lytb) (VShape q1 lyt1) (VShape q2 lyt2) = do
    -- The right input vector has only one boolean column which
    -- defines wether the tuple at the same position in the left input
    -- is preserved.
    let leftWidth = columnsInLayout lyt1
        predicate = Column $ leftWidth + 1

    VShape trueSelVec _        <- distSingleton (VShape q1 lyt1) qb lytb
    (trueVec, trueRenameVec)   <- vlSelect predicate 
                                  =<< vlAlign q1 trueSelVec
    trueVec'                   <- vlProject (map Column [1..leftWidth]) trueVec

    let predicate' = UnApp (L.SUBoolOp L.Not) predicate

    VShape falseSelVec _       <- distSingleton (VShape q2 lyt2) qb lytb
    (falseVec, falseRenameVec) <- vlSelect predicate' 
                                  =<< vlAlign q2 falseSelVec
    falseVec'                  <- vlProject (map Column [1..leftWidth]) falseVec

    lyt1'                      <- renameOuter' trueRenameVec lyt1
    lyt2'                      <- renameOuter' falseRenameVec lyt2
    lyt'                       <- appendLayout lyt1' lyt2'

    (bothBranches, _, _)       <- vlAppend trueVec' falseVec'

    return $ VShape bothBranches lyt'
ifList qb (SShape q1 lyt1) (SShape q2 lyt2) = do
    (VShape q lyt) <- ifList qb (VShape q1 lyt1) (VShape q2 lyt2)
    return $ SShape q lyt
ifList _ _ _ = $impossible

pair ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
pair (SShape q1 lyt1) (SShape q2 lyt2) = do
    q <- vlAlign q1 q2
    let lyt = zipLayout lyt1 lyt2
    return $ SShape q lyt
pair (VShape q1 lyt1) (VShape q2 lyt2) = do
    d   <- vlLit L.PossiblyEmpty [] [[VLInt 1, VLInt 1]]
    q1' <- vlUnsegment q1
    q2' <- vlUnsegment q2
    let lyt = zipLayout (LNest q1' lyt1) (LNest q2' lyt2)
    return $ SShape d lyt
pair (VShape q1 lyt1) (SShape q2 lyt2) = do
    q1' <- vlUnsegment q1
    let lyt = zipLayout (LNest q1' lyt1) lyt2
    return $ SShape q2 lyt
pair (SShape q1 lyt1) (VShape q2 lyt2) = do
    q2' <- vlUnsegment q2
    let lyt = zipLayout lyt1 (LNest q2' lyt2)
    return $ SShape q1 lyt

-- FIXME column offsets are not correct (see tupleL)
tuple :: [Shape VLDVec] -> Build VL (Shape VLDVec)
tuple (SShape q1 lyt1 : SShape q2 lyt2 : []) = do
    q <- vlAlign q1 q2
    let lyt = zipLayout lyt1 lyt2
    return $ SShape q lyt
tuple (VShape q1 lyt1 : VShape q2 lyt2 : []) = do
    d   <- vlLit L.PossiblyEmpty [] [[VLInt 1, VLInt 1]]
    q1' <- vlUnsegment q1
    q2' <- vlUnsegment q2
    let lyt = zipLayout (LNest q1' lyt1) (LNest q2' lyt2)
    return $ SShape d lyt
tuple (VShape q1 lyt1 : SShape q2 lyt2 : []) = do
    q1' <- vlUnsegment q1
    let lyt = zipLayout (LNest q1' lyt1) lyt2
    return $ SShape q2 lyt
tuple (SShape q1 lyt1 : VShape q2 lyt2 : []) = do
    q2' <- vlUnsegment q2
    let lyt = zipLayout lyt1 (LNest q2' lyt2)
    return $ SShape q1 lyt
tuple (SShape q1 lyt1 : shapes) = do
    SShape qt (LTuple lyts) <- tuple shapes
    q <- vlAlign q1 qt
    let lyt = LTuple $ zipLayouts (lyt1 : lyts)
    return $ SShape q lyt

tuple (VShape q1 lyt1 : shapes) = do
    SShape qt (LTuple lyts) <- tuple shapes
    q1' <- vlUnsegment q1
    return $ SShape qt (LTuple $ LNest q1' lyt1 : lyts)
tuple _ = $impossible
    

tupElem :: TupleIndex -> Shape VLDVec -> Build VL (Shape VLDVec)
tupElem i (SShape q (LTuple lyts)) =
    case lyts !! (tupleIndex i - 1) of
        LNest qi lyt -> return $ VShape qi lyt
        lyt          -> do
            let (lyt', cols) = projectFromPos lyt
            proj <- vlProject (map Column cols) q
            return $ SShape proj lyt'
tupElem _ _ = $impossible

transpose :: Shape VLDVec -> Build VL (Shape VLDVec)
transpose (VShape _ (LNest qi lyt)) = do
    (qo', qi') <- vlTranspose qi
    return $ VShape qo' (LNest qi' lyt)
transpose _ = $impossible


reshape :: Integer -> Shape VLDVec -> Build VL (Shape VLDVec)
reshape n (VShape q lyt) = do
    (qo, qi) <- vlReshape n q
    return $ VShape qo (LNest qi lyt)
reshape _ _ = $impossible

concat :: Shape VLDVec -> Build VL (Shape VLDVec)
concat (VShape _ (LNest q lyt)) = VShape <$> vlUnsegment q <*> pure lyt
concat _e                       = $impossible

--------------------------------------------------------------------------------
-- Construction of lifted primitives

restrictL :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
restrictL (VShape qo (LNest qi lyt)) (VShape _ (LNest qb (LCol 1))) = do
    VShape qi' lyt' <- restrict (VShape qi lyt) (VShape qb (LCol 1))
    return $ VShape qo (LNest qi' lyt')
restrictL l1                              l2                          =
    trace (show l1 ++ " " ++ show l2) $ $impossible

combineL :: Shape VLDVec -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
combineL (VShape qo (LNest qb (LCol 1)))
         (VShape _ (LNest qi1 lyt1))
         (VShape _ (LNest qi2 lyt2)) = do
    VShape qi' lyt' <- combine (VShape qb (LCol 1)) (VShape qi1 lyt1) (VShape qi2 lyt2)
    return $ VShape qo (LNest qi' lyt')
combineL _ _ _ = $impossible

zipL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
zipL (VShape d1 (LNest q1 lyt1)) (VShape _ (LNest q2 lyt2)) = do
    (q', r1, r2) <- vlZipS q1 q2
    lyt1'        <- chainRenameFilter r1 lyt1
    lyt2'        <- chainRenameFilter r2 lyt2
    return $ VShape d1 (LNest q' $ zipLayout lyt1' lyt2')
zipL _ _ = $impossible

cartProductL :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
cartProductL (VShape d1 (LNest q1 lyt1)) (VShape _ (LNest q2 lyt2)) = do
    (q', p1, p2) <- vlCartProductS q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ VShape d1 (LNest q' $ zipLayout lyt1' lyt2')
cartProductL _ _ = $impossible

nestProductL :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
nestProductL (VShape qd1 (LNest qv1 lyt1)) (VShape _qd2 (LNest qv2 lyt2)) = do
    (qj, qp2) <- vlNestProductS qv1 qv2
    lyt2'     <- chainReorder qp2 lyt2
    let lytJ  = zipLayout lyt1 lyt2'
    return $ VShape qd1 (LNest qv1 (LTuple [lyt1, (LNest qj lytJ)]))
nestProductL _ _ = $impossible

thetaJoinL :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
thetaJoinL joinPred (VShape d1 (LNest q1 lyt1)) (VShape _ (LNest q2 lyt2)) = do
    (q', p1, p2) <- vlThetaJoinS joinPred q1 q2
    lyt1'        <- chainReorder p1 lyt1
    lyt2'        <- chainReorder p2 lyt2
    return $ VShape d1 (LNest q' $ zipLayout lyt1' lyt2')
thetaJoinL _ _ _ = $impossible

-- △^L :: [[a]] -> [[b]] -> [[(a, [(a, b)])]]

-- For the unlifted nestjoin, we could segment the left (outer) input
-- and then use the regular thetajoin implementation. This trick does
-- not work here, as the lifted thetajoin joins on the
-- descriptors. Therefore, we have to 'segment' **after** the join,
-- i.e. use the left input positions as descriptors
nestJoinL :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
nestJoinL joinPred (VShape qd1 (LNest qv1 lyt1)) (VShape _qd2 (LNest qv2 lyt2)) = do
    (qj, qp2) <- vlNestJoinS joinPred qv1 qv2
    lyt2'     <- chainReorder qp2 lyt2
    let lytJ  = zipLayout lyt1 lyt2'
    return $ VShape qd1 (LNest qv1 (LTuple [lyt1,(LNest qj lytJ)]))
nestJoinL _ _ _ = $impossible

semiJoinL :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
semiJoinL joinPred (VShape d1 (LNest q1 lyt1)) (VShape _ (LNest q2 _)) = do
    (qj, r) <- vlSemiJoinS joinPred q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ VShape d1 (LNest qj lyt1')
semiJoinL _ _ _ = $impossible

antiJoinL :: L.JoinPredicate L.JoinExpr -> Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
antiJoinL joinPred (VShape d1 (LNest q1 lyt1)) (VShape _ (LNest q2 _)) = do
    (qj, r) <- vlAntiJoinS joinPred q1 q2
    lyt1'   <- chainRenameFilter r lyt1
    return $ VShape d1 (LNest qj lyt1')
antiJoinL _ _ _ = $impossible



nubL ::  Shape VLDVec -> Build VL (Shape VLDVec)
nubL (VShape d (LNest q lyt)) =  VShape d <$> (LNest <$> vlUniqueS q <*> pure lyt)
nubL _ = $impossible

numberL ::  Shape VLDVec -> Build VL (Shape VLDVec)
numberL (VShape d (LNest q lyt)) =
    VShape d <$> (LNest <$> vlNumberS q
                            <*> (pure $ zipLayout lyt (LCol 1)))
numberL _ = $impossible

initL ::  Shape VLDVec -> Build VL (Shape VLDVec)
initL (VShape qs (LNest q lyt)) = do
    is         <- vlAggrS AggrCount qs q
    (q', r, _) <- vlSelectPosS q (L.SBRelOp L.Lt) is
    lyt'       <- chainRenameFilter r lyt
    return $ VShape qs (LNest q' lyt')
initL _ = $impossible

lastL ::  Shape VLDVec -> Build VL (Shape VLDVec)
lastL (VShape d (LNest qs lyt@(LNest _ _))) = do
    is          <- vlAggrS AggrCount d qs
    (qs', r, _) <- vlSelectPosS qs (L.SBRelOp L.Eq) is
    lyt'        <- chainRenameFilter r lyt
    re          <- vlUnboxRename qs'
    VShape d <$> renameOuter' re lyt'
lastL (VShape d (LNest qs lyt)) = do
    is          <- vlAggrS AggrCount d qs
    (qs', r, _) <- vlSelectPosS qs (L.SBRelOp L.Eq) is
    lyt'        <- chainRenameFilter r lyt
    re          <- vlUnboxRename d
    renameOuter re (VShape qs' lyt')
lastL _ = $impossible

indexL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
indexL (VShape d (LNest qs (LNest qi lyti))) (VShape idxs (LCol 1)) = do
    idxs'          <- vlProject [BinApp (L.SBNumOp L.Add) (Column 1) (Constant $ VLInt 1)] idxs
    (_, _, u)      <- vlSelectPosS qs (L.SBRelOp L.Eq) idxs'
    (qu, ri)       <- vlUnboxNested u qi
    lyti'          <- chainRenameFilter ri lyti
    return $ VShape d (LNest qu lyti')
indexL (VShape d (LNest qs lyt)) (VShape idxs (LCol 1)) = do
    idxs'          <- vlProject [BinApp (L.SBNumOp L.Add) (Column 1) (Constant $ VLInt 1)] idxs
    (qs', r, _)    <- vlSelectPosS qs (L.SBRelOp L.Eq) idxs'
    lyt'           <- chainRenameFilter r lyt
    re             <- vlUnboxRename d
    renameOuter re (VShape qs' lyt')
indexL _ _ = $impossible

appendL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
appendL (VShape d lyt1) (VShape _ lyt2) = do
    VShape d <$> appendLayout lyt1 lyt2
appendL _ _ = $impossible

reverseL ::  Shape VLDVec -> Build VL (Shape VLDVec)
reverseL (VShape d (LNest d1 lyt)) = do
    (d1', p) <- vlReverseS d1
    lyt'     <- chainReorder p lyt
    return (VShape d (LNest d1' lyt'))
reverseL _ = $impossible

theL ::  Shape VLDVec -> Build VL (Shape VLDVec)
theL (VShape d (LNest q lyt)) = do
    (v, p2, _) <- vlSelectPos1S q (L.SBRelOp L.Eq) 1
    prop       <- vlUnboxRename d
    lyt'       <- chainRenameFilter p2 lyt
    v'         <- vlPropRename prop v
    return $ VShape v' lyt'
theL _ = $impossible

tailL ::  Shape VLDVec -> Build VL (Shape VLDVec)
tailL (VShape d (LNest q lyt)) = do
    p              <- vlProject [Constant $ VLInt 1] d
    (v, p2, _)     <- vlSelectPosS q (L.SBRelOp L.Gt) p
    lyt'           <- chainRenameFilter p2 lyt
    return $ VShape d (LNest v lyt')
tailL _ = $impossible

sortL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
sortL (VShape _ (LNest v1 lyt1)) (VShape d2 (LNest v2 lyt2)) = do
    VShape innerVec lyt <- sort (VShape v1 lyt1) (VShape v2 lyt2)
    return $ VShape d2 (LNest innerVec lyt)
sortL _ _ = $impossible

groupL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
groupL (VShape _ (LNest v1 lyt1)) (VShape d2 (LNest v2 lyt2)) = do
    let flatRes = group (VShape v1 lyt1) (VShape v2 lyt2)
    (VShape middleVec (LTuple [groupLyt, LNest innerVec innerLyt])) <- flatRes
    return $ VShape d2 (LNest middleVec (LTuple [groupLyt, LNest innerVec innerLyt]))
groupL _ _ = $impossible

concatL ::  Shape VLDVec -> Build VL (Shape VLDVec)
concatL (VShape d (LNest d' vs)) = do
    p   <- vlUnboxRename d'
    vs' <- renameOuter' p vs
    return $ VShape d vs'
concatL _ = $impossible

lengthL ::  Shape VLDVec -> Build VL (Shape VLDVec)
lengthL (VShape q (LNest qi _)) = do
    ls  <- vlAggrS AggrCount q qi
    lsu <- vlUnboxScalar q ls
    return $ VShape lsu (LCol 1)
lengthL s = trace (show s) $ $impossible

consL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
consL (VShape q1 lyt1) (VShape q2 (LNest qi lyt2)) = do
    s           <- vlSegment q1
    (v, p1, p2) <- vlAppendS s qi
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    lyt'        <- appendLayout lyt1' lyt2'
    return $ VShape q2 (LNest v lyt')
consL _ _ = $impossible

outer ::  Shape VLDVec -> Build VL VLDVec
outer (SShape _ _)        = $impossible
outer (VShape q _)        = return q

aggrL :: (Expr -> AggrFun) -> Shape VLDVec -> Build VL (Shape VLDVec)
aggrL afun (VShape d (LNest q (LCol 1))) = do
    qr <- vlAggrS (afun (Column 1)) d q
    qu <- vlUnboxScalar d qr
    return $ VShape qu (LCol 1)
aggrL _ _ = $impossible

distL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
distL (VShape q1 lyt1) (VShape d (LNest q2 lyt2)) = do
    (qa, p)             <- vlDistLift q1 q2
    lyt1'               <- chainReorder p lyt1
    let lyt             = zipLayout lyt1' lyt2
    VShape qf lytf <- tupElemL First $ VShape qa lyt
    return $ VShape d (LNest qf lytf)
distL _e1 _e2 = $impossible

pairL ::  Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
pairL (VShape q1 lyt1) (VShape q2 lyt2) = do
    q <- vlAlign q1 q2
    let lyt = zipLayout lyt1 lyt2
    return $ VShape q lyt
pairL _ _ = $impossible

tupleL :: [Shape VLDVec] -> Build VL (Shape VLDVec)
tupleL shapes@(_ : _) = do
    (q, lyts) <- zipVectors shapes
    let lyts' = zipLayouts lyts
    return $ VShape q (LTuple lyts')
tupleL _ = $impossible

tupElemL :: TupleIndex -> Shape VLDVec -> Build VL (Shape VLDVec)
tupElemL i (VShape q (LTuple lyts)) = do
    let (lyt', cols) = projectFromPos $ lyts !! (tupleIndex i - 1)
    proj <- vlProject (map Column cols) q
    return $ VShape proj lyt'
tupElemL i s = trace (show i ++ " " ++ show s) $impossible

transposeL :: Shape VLDVec -> Build VL (Shape VLDVec)
transposeL (VShape qo (LNest qm (LNest qi lyt))) = do
    (qm', qi') <- vlTransposeS qm qi
    return $ VShape qo (LNest qm' (LNest qi' lyt))
transposeL _ = $impossible

reshapeL :: Integer -> Shape VLDVec -> Build VL (Shape VLDVec)
reshapeL n (VShape qo (LNest qi lyt)) = do
    (qm, qi') <- vlReshapeS n qi
    return $ VShape qo (LNest qm (LNest qi' lyt))
reshapeL _ _ = $impossible

-- | Create a projection list that extracts only those columns
-- referenced in the sub-layout passed as argument, and shift column
-- names in the sub-layout to the beginning.
projectFromPos :: Layout VLDVec -> (Layout VLDVec , [DBCol])
projectFromPos = (\(x,y,_) -> (x,y)) . (projectFromPosWork 1)
  where
    projectFromPosWork :: Int -> Layout VLDVec -> (Layout VLDVec, [DBCol], Int)
    projectFromPosWork c (LCol i)      = (LCol c, [i], c + 1)
    projectFromPosWork c (LNest q l)   = (LNest q l, [], c)
    projectFromPosWork c (LTuple lyts) = (LTuple psRes, colsRes, cRes)
      where
        (psRes, colsRes, cRes) = List.foldl' tupleWorker ([], [], c) lyts

    tupleWorker (psAcc, colsAcc, cAcc) lyt = (psAcc ++ [lyt'], colsAcc ++ cols, c')
      where
        (lyt', cols, c') = projectFromPosWork cAcc lyt

singletonVec ::  Shape VLDVec -> Build VL (Shape VLDVec)
singletonVec (VShape q lyt) = do
    VLDVec d <- vlSingletonDescr
    return $ VShape (VLDVec d) (LNest q lyt)
singletonVec _ = $impossible

singletonAtom ::  Shape VLDVec -> Build VL (Shape VLDVec)
singletonAtom (SShape q1 lyt) = return $ VShape q1 lyt
singletonAtom _ = $impossible

--------------------------------------------------------------------------------
-- Construction of base tables and literal tables

-- | Create a VL reference to a base table.
dbTable ::  String -> [L.Column] -> L.TableHints -> Build VL (Shape VLDVec)
dbTable n cs ks = do
    t <- vlTableRef n (map (mapSnd typeToScalarType) cs) ks
    return $ VShape t (LTuple [LCol i | i <- [1..length cs]])

-- | Create a VL representation of a literal value.
mkLiteral ::  Type -> L.Val -> Build VL (Shape VLDVec)
-- Translate an outer list
mkLiteral t@(ListT _) (L.ListV es) = do
    ((tabTys, tabCols), lyt, _) <- toPlan (mkDescriptor [P.length es]) t 1 es
    let emptinessFlag = case es of
          []    -> L.PossiblyEmpty
          _ : _ -> L.NonEmpty
    litNode <- vlLit emptinessFlag (P.reverse tabTys) $ map P.reverse tabCols
    return $ VShape litNode lyt
mkLiteral (FunT _ _) _  = $impossible
-- Translate a non-list value, i.e. scalar or tuple
mkLiteral t e           = do
    -- There is only one element in the outermost vector
    ((tabTys, [tabCols]), layout, _) <- toPlan (mkDescriptor [1]) (ListT t) 1 [e]
    litNode <- vlLit L.NonEmpty (P.reverse tabTys) [(P.reverse tabCols)]
    return $ SShape litNode layout

type Table = ([Type], [[VLVal]])

-- | Add values to a vector. If necessary (i.e. inner lists are
-- encountered), create new inner vectors. 'toPlan' receives a
-- descriptor that has enough space for all elements of the list that
-- are currently encoded.

-- FIXME Check if inner list literals are nonempty and flag VL
-- literals appropriately.  
toPlan ::  Table -> Type -> Int -> [L.Val] -> Build VL (Table, Layout VLDVec, Int)
toPlan (tabTys, tabCols) (ListT t) nextCol es =
    -- Inspect the element type of the list to be encoded
    case t of
        ListT _ -> do
            let vs = map listElems es
                -- Create a vector with one entry for each element of an inner list
                d  = mkDescriptor $ map P.length vs
            -- Add the inner list elements to the vector
            ((innerTabTys, innerTabCols), lyt, _) <- toPlan d t 1 (P.concat vs)
            n <- vlLit L.PossiblyEmpty (P.reverse innerTabTys) (map P.reverse innerTabCols)
            return ((tabTys, tabCols), LNest n lyt, nextCol)

        TupleT elemTys -> do
            -- We add tuple elements column-wise. If the list to be
            -- encoded is empty, create an empty list for each column.
            let colsVals = case es of
                               [] -> map (const []) elemTys
                               _  -> List.transpose $ map tupleElems es
            mkTupleTable (tabTys, tabCols) nextCol [] colsVals elemTys

        FunT _ _  -> $impossible

        _ -> let (hd, vs) = mkColumn t es
             in return ((hd:tabTys, zipWith (:) vs tabCols), (LCol nextCol), nextCol + 1)

toPlan _ (FunT _ _) _ _ = $impossible
toPlan (tabTys, tabCols) t c v =
    let (hd, v') = mkColumn t v
    in return $ ((hd:tabTys, zipWith (:) v' tabCols), (LCol c), c + 1)

-- | Construct the literal table for a list of tuples.
mkTupleTable :: Table                         -- ^ The literal table so far.
   -> Int                                     -- ^ The next available column offset
   -> [Layout VLDVec]                         -- ^ The layouts of the tuple elements constructed so far
   -> [[L.Val]]                               -- ^ Values for the tuple elements
   -> [Type]                                  -- ^ Types for the tuple elements
   -> Build VL (Table, Layout VLDVec, Int)
mkTupleTable tab nextCol lyts (colVals : colsVals) (t : ts) = do
    (tab', lyt, nextCol') <- toPlan tab (ListT t) nextCol colVals
    mkTupleTable tab' nextCol' (lyt : lyts) colsVals ts
mkTupleTable tab nextCol lyts []                   []       = do
    return $ (tab, LTuple $ P.reverse lyts, nextCol)
mkTupleTable _   _       _    _                    _        = $impossible

literal :: Type -> VLVal -> Build VL VLDVec
literal t v = vlLit L.NonEmpty [t] [[VLInt 1, VLInt 1, v]]

listElems :: L.Val -> [L.Val]
listElems (L.ListV es) = es
listElems _            = $impossible

tupleElems :: L.Val -> [L.Val]
tupleElems (L.TupleV es) = es
tupleElems _             = $impossible

mkColumn :: Type -> [L.Val] -> (Type, [VLVal])
mkColumn t vs = (t, [pVal v | v <- vs])

mkDescriptor :: [Int] -> Table
mkDescriptor lengths =
    let header = []
        body   = [ [VLInt $ fromInteger p, VLInt $ fromInteger d]
                 | d <- P.concat [ replicate l p | p <- [1..] | l <- lengths ]  
                 | p <- [1..]
                 ]
    in (header, body)

--------------------------------------------------------------------------------
-- Helper functions for zipping/tuple construction

zipLayout :: Layout VLDVec -> Layout VLDVec -> Layout VLDVec
zipLayout l1 l2 = let offSet = columnsInLayout l1
                      l2' = incrementPositions offSet l2
                   in LTuple [l1, l2']

incrementPositions :: Int -> Layout VLDVec -> Layout VLDVec
incrementPositions i (LCol n)       = LCol $ n + i
incrementPositions _i v@(LNest _ _) = v
incrementPositions i (LTuple lyts)  = LTuple $ map (incrementPositions i) lyts

zipLayouts :: [Layout VLDVec] -> [Layout VLDVec]
zipLayouts layouts = go 0 layouts

  where
    go :: Int -> [Layout VLDVec] -> [Layout VLDVec]
    go 0 (lyt : lyts) = lyt : go (columnsInLayout lyt) lyts
    go o (lyt : lyts) = incrementPositions o lyt : go (o + columnsInLayout lyt) lyts
    go _ []           = []

zipVectors :: [Shape VLDVec] -> Build VL (VLDVec, [Layout VLDVec])
zipVectors (VShape q1 lyt1 : [])     = return (q1, [lyt1])
zipVectors (VShape q1 lyt1 : shapes) = do
    (q, lyts) <- zipVectors shapes
    qz' <- vlAlign q1 q
    return (qz', lyt1 : lyts)
zipVectors _ = $impossible

--------------------------------------------------------------------------------
-- Compile-time operations that implement higher-lifted primitives.

-- | Remove the 'n' outer layers of nesting from a nested list
-- (Prins/Palmer: 'extract').
qConcat :: Nat -> Shape VLDVec -> Shape VLDVec
qConcat Zero _                               = $impossible
qConcat (Succ Zero) (VShape _ (LNest q lyt)) = VShape q lyt
qConcat (Succ n)    (VShape _ lyt)           = extractInnerVec n lyt
qConcat _           _                        = $impossible

extractInnerVec :: Nat -> Layout VLDVec -> Shape VLDVec
extractInnerVec (Succ Zero) (LNest _ (LNest q lyt)) = VShape q lyt
extractInnerVec (Succ n)    (LNest _ lyt)           = extractInnerVec n lyt
extractInnerVec n           l                       = trace (show n ++ " " ++ show l) $impossible

-- | Prepend the 'n' outer layers of nesting from the first input to
-- the second input (Prins/Palmer: 'insert').
unconcat :: Nat -> Shape VLDVec -> Shape VLDVec -> Shape VLDVec
unconcat (Succ Zero) (VShape d _) (VShape vi lyti) =
    VShape d (LNest vi lyti)
unconcat (Succ n) (VShape d lyt) (VShape vi lyti)  =
    VShape d (implantInnerVec n lyt vi lyti)
unconcat _          _                   _          =
    $impossible

implantInnerVec :: Nat -> Layout VLDVec -> VLDVec -> Layout VLDVec -> Layout VLDVec
implantInnerVec (Succ Zero) (LNest d _)   vi lyti   =
    LNest d $ LNest vi lyti
implantInnerVec (Succ n)      (LNest d lyt) vi lyti =
    LNest d $ implantInnerVec n lyt vi lyti
implantInnerVec _          _            _  _        =
    $impossible

--------------------------------------------------------------------------------
-- Vectorization Helper Functions

-- | Take a shape apart by extracting the vector, the layout and the
-- shape constructor itself.
unwrapShape :: Shape VLDVec -> (VLDVec -> Layout VLDVec -> Shape VLDVec, VLDVec, Layout VLDVec)
unwrapShape (VShape q lyt) = (VShape, q, lyt)
unwrapShape (SShape q lyt) = (SShape, q, lyt)

fromLayout :: Layout VLDVec -> [DBCol]
fromLayout (LCol i)      = [i]
fromLayout (LNest _ _)   = []
fromLayout (LTuple lyts) = concatMap fromLayout lyts

-- | chainRenameFilter renames and filters a vector according to a rename vector
-- and propagates these changes to all inner vectors. No reordering is applied,
-- that is the propagation vector must not change the order of tuples.
chainRenameFilter :: RVec -> Layout VLDVec -> Build VL (Layout VLDVec)
chainRenameFilter _ l@(LCol _) = return l
chainRenameFilter r (LNest q lyt) = do
    (q', r') <- vlPropFilter r q
    lyt'     <- chainRenameFilter r' lyt
    return $ LNest q' lyt'
chainRenameFilter r (LTuple lyts) =
    LTuple <$> mapM (chainRenameFilter r) lyts

-- | chainReorder renames and filters a vector according to a propagation vector
-- and propagates these changes to all inner vectors. The propagation vector
-- may change the order of tuples.
chainReorder :: PVec -> Layout VLDVec -> Build VL (Layout VLDVec)
chainReorder _ l@(LCol _) = return l
chainReorder p (LNest q lyt) = do
    (q', p') <- vlPropReorder p q
    lyt'     <- chainReorder p' lyt
    return $ LNest q' lyt'
chainReorder p (LTuple lyts) =
    LTuple <$> mapM (chainReorder p) lyts

-- | renameOuter renames and filters a vector according to a rename
-- vector. Changes are not propagated to inner vectors.
renameOuter :: RVec -> Shape VLDVec -> Build VL (Shape VLDVec)
renameOuter p (VShape q lyt) = flip VShape lyt <$> vlPropRename p q
renameOuter _ _ = error "renameOuter: Not possible"

renameOuter' :: RVec -> Layout VLDVec -> Build VL (Layout VLDVec)
renameOuter' _ l@(LCol _)    = return l
renameOuter' r (LNest q lyt) = flip LNest lyt <$> vlPropRename r q
renameOuter' r (LTuple lyts) = LTuple <$> mapM (renameOuter' r) lyts

-- | Append two inner vectors (segment-wise).
appendInnerVec :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
appendInnerVec (VShape q1 lyt1) (VShape q2 lyt2) = do
    -- Append the current vectors
    (v, p1, p2) <- vlAppendS q1 q2
    -- Propagate position changes to descriptors of any inner vectors
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    -- Append the layouts, i.e. actually append all inner vectors
    lyt'        <- appendLayout lyt1' lyt2'
    return $ VShape v lyt'
appendInnerVec _ _ = $impossible

-- | Append two (outer) vectors regularly.
appendVec :: Shape VLDVec -> Shape VLDVec -> Build VL (Shape VLDVec)
appendVec (VShape q1 lyt1) (VShape q2 lyt2) = do
    -- Append the current vectors
    (v, p1, p2) <- vlAppend q1 q2
    -- Propagate position changes to descriptors of any inner vectors
    lyt1'       <- renameOuter' p1 lyt1
    lyt2'       <- renameOuter' p2 lyt2
    -- Append the layouts, i.e. actually append all inner vectors
    lyt'        <- appendLayout lyt1' lyt2'
    return $ VShape v lyt'
appendVec _ _ = $impossible

-- | Traverse a layout and append all nested vectors that are
-- encountered.
appendLayout :: Layout VLDVec -> Layout VLDVec -> Build VL (Layout VLDVec)
appendLayout (LCol i1) (LCol i2)
    | i1 == i2  = return $ LCol i1
    | otherwise = error "appendR': Incompatible vectors"
-- Append two nested vectors
appendLayout (LNest q1 lyt1) (LNest q2 lyt2) = do
    a <- appendInnerVec (VShape q1 lyt1) (VShape q2 lyt2)
    case a of
        VShape q lyt -> return $ LNest q lyt
        _            -> $impossible
appendLayout (LTuple lyts1) (LTuple lyts2) =
    LTuple <$> (sequence $ zipWith appendLayout lyts1 lyts2)
appendLayout _ _ = $impossible
