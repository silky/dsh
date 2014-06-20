{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE PatternSynonyms #-}

module Database.DSH.CL.Opt.AntiJoin
    ( antijoinR
    ) where

import Debug.Trace

import           Control.Arrow
import           Control.Applicative
import           Data.List.NonEmpty         (NonEmpty ((:|)))
import           Data.Semigroup
import qualified Data.Traversable as T
import Data.List
import qualified Data.List.NonEmpty as NL

import           Database.DSH.CL.Kure
import           Database.DSH.CL.Lang
import           Database.DSH.CL.Opt.Aux
import qualified Database.DSH.CL.Primitives as P
import           Database.DSH.Common.Lang
import           Database.DSH.Impossible

--------------------------------------------------------------------------------
-- Introduce anti joins (universal quantification)

--------------------------------------------------------------------------------
-- Basic antijoin pattern

-- | Construct an antijoin qualifier given a predicate and two generators. Note
-- that the splitJoinPred call implicitly checks that only x and y occur free in
-- the predicate and no further correlation takes place.
mkantijoinT :: Expr -> Ident -> Ident -> Expr -> Expr -> TransformC (NL Qual) Qual
mkantijoinT joinPred x y xs ys = do
    joinConjunct <- constT (return joinPred) >>> splitJoinPredT x y

    let xst = typeOf xs
        yst = typeOf ys
        jt  = xst .-> yst .-> xst

    -- => [ ... | ..., x <- xs antijoin(p1, p2) ys, ... ]
    return $ BindQ x (AppE2 xst (Prim2 (AntiJoin $ singlePred joinConjunct) jt) xs ys)

-- | Match the basic antijoin pattern in the middle of a qualifier list. This is
-- essentially the operator definition, generalized to multiple qualifiers and
-- an arbitrary comprehension head:
-- [ f x | qs, x <- xs, and [ not (q y) | y <- ys ], qs' ]
-- => [ f x | qs, x <- xs antijoin(q) ys, qs' ]
basicAntiJoinR :: RewriteC (NL Qual)
basicAntiJoinR = do
    -- [ ... | ..., x <- xs, and [ not p | y <- ys ], ... ]
    BindQ x xs :* GuardQ (AppE1 _ (Prim1 And _)
                                  (Comp _ (UnOp _ (SUBoolOp Not) p)
                                          (S (BindQ y ys))))  :* qs <- idR
    q' <- mkantijoinT p x y xs ys
    return $ q' :* qs

-- | Match a NOT IN antijoin pattern at the end of a list
basicAntiJoinEndR :: RewriteC (NL Qual)
basicAntiJoinEndR = do
    -- [ ... | ..., x <- xs, and [ True | y <- ys, not p ] ]
    BindQ x xs :* S (GuardQ (AppE1 _ (Prim1 And _)
                                     (Comp _ (UnOp _ (SUBoolOp Not) p)
                                             (S (BindQ y ys))))) <- idR
    q' <- mkantijoinT p x y xs ys
    return (S q')

--------------------------------------------------------------------------------
-- Doubly Negated existential quantifier (NOT EXISTS)

--------------------------------------------------------------------------------
-- Universal quantification with range predicates

-- | Turn universal quantification with range and quantifier predicates into an
-- antijoin. We use the classification of queries in Claussen et al.: Optimizing
-- Queries with Universal Quantification in Object-Oriented and
-- Object-Relational Databases (VLDB 1995).

pattern PAnd xs <- AppE1 _ (Prim1 And _) xs
pattern PNot e <- UnOp _ (SUBoolOp Not) e

-- | Split a conjunctive combination of join predicates.
conjunctsT :: Ident -> Ident -> TransformC CL (NonEmpty (JoinConjunct JoinExpr))
conjunctsT x y = readerT $ \e -> case e of
    -- For a logical AND, turn the left and right arguments into lists
    -- of join predicates and combine them.
    ExprCL (BinOp _ (SBBoolOp Conj) e1 e2) -> do
        leftConjs  <- childT BinOpArg1 (conjunctsT x y)
        rightConjs <- childT BinOpArg2 (conjunctsT x y)
        return $ leftConjs <> rightConjs

    -- For a non-AND expression, try to transform it into a join
    -- predicate.
    _ -> (:|) <$> promoteT (splitJoinPredT x y) <*> pure []

negateRelOp :: Monad m => BinRelOp -> m BinRelOp
negateRelOp op = case op of
    Eq  -> return NEq
    NEq -> return Eq
    GtE -> return Lt
    LtE -> return Gt
    _   -> fail "can not simply negate <, >"

-- | Quantifier predicates that reference inner and outer relation
-- appear negated on the antijoin.
quantifierPredicateT :: Ident -> Ident -> TransformC CL (NonEmpty (JoinConjunct JoinExpr))
quantifierPredicateT x y = readerT $ \q -> case q of
    -- If the quantifier predicate is already negated, take its
    -- non-negated form.
    ExprCL (PNot conjunctivePred) -> do
        conjs <- childT UnOpArg (conjunctsT x y)
        return conjs

    -- If the predicate is a simple relational operator, but
    -- non-negated, try to negate the operator itself.
    ExprCL (BinOp t (SBRelOp op) e1 e2) -> do
        op' <- constT $ negateRelOp op
        let e' = BinOp t (SBRelOp op') e1 e2
        q' <- constT (return e') >>> splitJoinPredT x y
        return $ q' :| []
        
    _                          -> fail "can't handle predicate"


universalQualR :: RewriteC (NL Qual)
universalQualR = readerT $ \qs -> case qs of
    -- [ ... | ..., x <- xs, and [ q | y <- ys, ps ], ... ]
    BindQ x xs :* GuardQ (PAnd (Comp _ q (BindQ y ys :* ps))) :* qs -> do
        antijoinGen <- mkUniversalAntiJoinT (x, xs) (y, ys) ps q
        return $ antijoinGen :* qs

    -- [ ... | ..., x <- xs, and [ q | y <- ys, ps ]]
    BindQ x xs :* (S (GuardQ (PAnd (Comp _ q (BindQ y ys :* ps))))) -> do
        antijoinGen <- mkUniversalAntiJoinT (x, xs) (y, ys) ps q
        return $ S $ antijoinGen
    _ -> fail "no and pattern"

mkUniversalAntiJoinT :: (Ident, Expr) 
                     -> (Ident, Expr)
                     -> NL Qual
                     -> Expr
                     -> TransformC (NL Qual) Qual
mkUniversalAntiJoinT (x, xs) (y, ys) ps q = do
    psExprs <- constT $ T.mapM fromGuard ps
    let psFVs = sort $ nub $ concatMap freeVars $ toList psExprs
        qFVs  = sort $ nub $ freeVars q

    let xy = sort [x, y]

    debugMsg $ show psFVs
    debugMsg $ show qFVs
    debugMsg $ show xy

    case (psFVs, qFVs) of
        -- Class 12: p(y), q(x, y)
        ([y'], qsvs@[_, _]) | y == y' && qsvs == xy -> do
            qPred <- constT (return q) >>> injectT >>> quantifierPredicateT x y
            mkClass12AntiJoinT (x, xs) (y, ys) psExprs (JoinPred qPred)

        -- Class 15: p(x, y), q(y)
        (psvs@[_, _], [y']) | psvs == xy && y == y' -> do
            psConjs <- constT (return psExprs) >>> mapT (splitJoinPredT x y)
            let psPred = JoinPred $ toNonEmpty psConjs
            mkClass15AntiJoinT (x, xs) (y, ys) psPred q

        -- Class 16: p(x, y), q(x, y)
        (psvs@[_, _], qsvs@[_, _]) | psvs == xy && qsvs == xy -> do
            psConjs <- constT (return psExprs) >>> mapT (splitJoinPredT x y)
            qPred   <- constT (return q) >>> injectT >>> quantifierPredicateT x y
            mkClass16AntiJoinT (x, xs) ys (toNonEmpty psConjs) qPred

        _ -> fail "FIXME"


mkClass12AntiJoinT :: (Ident, Expr)               -- ^ Generator variable and expression for the outer
                   -> (Ident, Expr)
                   -> NL Expr
                   -> JoinPredicate JoinExpr
                   -> TransformC (NL Qual) Qual
mkClass12AntiJoinT (x, xs) (y, ys) ps qs = do
    let xst = typeOf xs
        xt  = elemT xst
        yst = typeOf ys
        yt  = elemT yst

    -- [ y | y <- ys, ps ]
    let ys' = Comp yst (Var yt y) (BindQ y ys :* fmap GuardQ ps)

    -- xs ▷_ps [ y | y <- ys, not qs ]
    return $ BindQ x (P.antijoin xs ys' qs)

-- This rewrite implements plan 14 for Query Class 15 in Claussen et al.,
-- Optimizing Queries with Universal Quantification... (VLDB, 1995).  Class 15
-- contains queries in which the range predicate ranges over both relations,
-- i.e. x and y occur free. The quantifier predicate on the other hand ranges
-- only over the inner relation:
-- p(x, y), q(y)
mkClass15AntiJoinT :: (Ident, Expr)               -- ^ Generator variable and expression for the outer
                   -> (Ident, Expr)
                   -> JoinPredicate JoinExpr
                   -> Expr
                   -> TransformC (NL Qual) Qual
mkClass15AntiJoinT (x, xs) (y, ys) ps qs = do
    let xst = typeOf xs
        xt  = elemT xst
        yst = typeOf ys
        yt  = elemT yst

    -- [ y | y <- ys, not q ]
    let ys' = Comp yst (Var yt y) (BindQ y ys :* S (GuardQ $ P.not qs))

    -- xs ▷_not(qs) [ y | y <- ys, ps ]
    return $ BindQ x (P.antijoin xs ys' ps)

mkClass16AntiJoinT :: (Ident, Expr)
                   -> Expr
                   -> NonEmpty (JoinConjunct JoinExpr) 
                   -> NonEmpty (JoinConjunct JoinExpr)
                   -> TransformC (NL Qual) (Qual)
mkClass16AntiJoinT (x, xs) ys ps qs = do
    let xst = typeOf xs
        xt  = elemT xst
        yst = typeOf ys
        yt  = elemT yst

    -- xs ▷_(p && not q) ys
    return $ BindQ x (P.antijoin xs ys $ JoinPred $ ps <> qs)

universalQualsR :: RewriteC (NL Qual)
universalQualsR = onetdR universalQualR

antijoinR :: RewriteC CL
antijoinR = do
    Comp _ _ _ <- promoteT idR
    childR CompQuals (promoteR universalQualsR)