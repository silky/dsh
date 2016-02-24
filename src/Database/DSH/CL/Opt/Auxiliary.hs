{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE PatternSynonyms       #-}

-- | Common tools for rewrites
module Database.DSH.CL.Opt.Auxiliary
    ( applyExpr
    , applyInjectable
      -- * Monad rewrites with additional state
    , TuplifyM
      -- * Converting predicate expressions into join predicates
    , toJoinExpr
    , splitJoinPredT
    , joinConjunctsT
    , conjunctsT
    -- * Pushing guards towards the front of a qualifier list
    , isThetaJoinPred
    , isSemiJoinPred
    , isAntiJoinPred
      -- * Free and bound variables
    , freeVars
    , boundVars
    , compBoundVars
      -- * Substituion
    , substR
    , tuplifyR
      -- * Combining generators and guards
    , insertGuard
      -- * Generic iterator to merge guards into generators
    , Comp(..)
    , MergeGuard
    , mergeGuardsIterR
      -- * Classification of expressions
    , complexPrim1
    , complexPrim2
    , fromGuard
    , fromQual
    , fromGen
      -- * NL spine traversal
    , onetdSpineT
      -- * Pattern synonyms for expressions
    , pattern ConcatP
    , pattern SingletonP
    , pattern GuardP
    , pattern SemiJoinP
    , pattern AndP
    , pattern NotP
    , pattern EqP
    , pattern LengthP
    , pattern OrP
    , pattern NullP
    , pattern TrueP
    ) where

import           Control.Arrow
import           Data.Either
import qualified Data.Foldable              as F
import           Data.List
import qualified Data.Set                   as S
import           Data.List.NonEmpty         (NonEmpty ((:|)))
import           Data.Semigroup             hiding (First)

import           Language.KURE

import           Database.DSH.CL.Kure
import           Database.DSH.CL.Lang
import           Database.DSH.Common.Lang
import           Database.DSH.Common.Nat
import           Database.DSH.Common.RewriteM
import           Database.DSH.Common.Impossible

-- | A version of the CompM monad in which the state contains an additional
-- rewrite. Use case: Returning a tuplify rewrite from a traversal over the
-- qualifier list so that it can be applied to the head expression.
type TuplifyM = RewriteStateM (RewriteC CL)

-- | Run a translate on an expression without context
applyExpr :: TransformC CL b -> Expr -> Either String b
applyExpr f e = runRewriteM $ applyT f initialCtx (inject e)

-- | Run a translate on any value which can be injected into CL
applyInjectable :: Injection a CL => TransformC CL b -> a -> Either String b
applyInjectable t e = runRewriteM $ applyT t initialCtx (inject e)

--------------------------------------------------------------------------------
-- Rewrite join predicates into general expressions.

toExpr :: TransformC JoinExpr Expr
toExpr = undefined

--------------------------------------------------------------------------------
-- Rewrite general expressions into equi-join predicates

toJoinBinOp :: Monad m => ScalarBinOp -> m JoinBinOp
toJoinBinOp (SBNumOp o)     = return $ JBNumOp o
toJoinBinOp (SBStringOp o)  = return $ JBStringOp o
toJoinBinOp (SBRelOp _)     = fail "toJoinBinOp: join expressions can't contain relational ops"
toJoinBinOp (SBBoolOp _)    = fail "toJoinBinOp: join expressions can't contain boolean ops"
toJoinBinOp (SBDateOp _)    = fail "toJoinBinOp: join expressions can't contain date ops"

toJoinUnOp :: Monad m => ScalarUnOp -> m JoinUnOp
toJoinUnOp (SUNumOp o)  = return $ JUNumOp o
toJoinUnOp (SUCastOp o) = return $ JUCastOp o
toJoinUnOp (SUTextOp o) = return $ JUTextOp o
toJoinUnOp (SUBoolOp _) = fail "toJoinUnOp: join expressions can't contain boolean ops"
toJoinUnOp (SUDateOp _) = fail "toJoinUnOp: join expressions can't contain date ops"

toJoinExpr :: Ident -> TransformC Expr JoinExpr
toJoinExpr n = do
    e <- idR

    case e of
        AppE1 _ (TupElem i) _ ->
            appe1T (toJoinExpr n) (\t _ e1 -> JTupElem t i e1)
        BinOp _ o _ _ -> do
            o' <- constT $ toJoinBinOp o
            binopT (toJoinExpr n) (toJoinExpr n) (\t _ e1 e2 -> JBinOp t o' e1 e2)
        UnOp _ o _ -> do
            o' <- constT $ toJoinUnOp o
            unopT (toJoinExpr n) (\t _ e1 -> JUnOp t o' e1)
        Lit t v       ->
            return $ JLit t v
        Var t x       -> do
            guardMsg (n == x) "toJoinExpr: wrong name"
            return $ JInput t
        _             ->
            fail "toJoinExpr: can't translate to join expression"

flipRelOp :: BinRelOp -> BinRelOp
flipRelOp Eq  = Eq
flipRelOp NEq = NEq
flipRelOp Gt  = Lt
flipRelOp Lt  = Gt
flipRelOp GtE = LtE
flipRelOp LtE = GtE

-- | Try to transform an expression into a thetajoin predicate. This
-- will fail if either the expression does not have the correct shape
-- (relational operator with simple projection expressions on both
-- sides) or if one side of the predicate has free variables which are
-- not the variables of the qualifiers given to the function.
splitJoinPredT :: Ident -> Ident -> TransformC Expr (JoinConjunct JoinExpr)
splitJoinPredT x y = do
    BinOp _ (SBRelOp op) e1 e2 <- idR

    [x'] <- return $ freeVars e1
    [y'] <- return $ freeVars e2

    if | x == x' && y == y' -> binopT (toJoinExpr x)
                                      (toJoinExpr y)
                                      (\_ _ e1' e2' -> JoinConjunct e1' op e2')
       | y == x' && x == y' -> binopT (toJoinExpr y)
                                      (toJoinExpr x)
                                      (\_ _ e1' e2' -> JoinConjunct e2' (flipRelOp op) e1')
       | otherwise          -> fail "splitJoinPredT: not a theta-join predicate"

-- | Split a conjunctive combination of join predicates.
joinConjunctsT :: Ident -> Ident -> TransformC CL (NonEmpty (JoinConjunct JoinExpr))
joinConjunctsT x y = conjunctsT >>> mapT (splitJoinPredT x y)

-- | Split a combination of logical conjunctions into its sub-terms.
conjunctsT :: TransformC CL (NonEmpty Expr)
conjunctsT = readerT $ \e -> case e of
    -- For a logical AND, turn the left and right arguments into lists
    -- of join predicates and combine them.
    ExprCL (BinOp _ (SBBoolOp Conj) _ _) -> do
        leftConjs  <- childT BinOpArg1 conjunctsT
        rightConjs <- childT BinOpArg2 conjunctsT
        return $ leftConjs <> rightConjs

    -- For a non-AND expression, try to transform it into a join
    -- predicate.
    ExprCL expr -> return $ expr :| []

    _ -> $impossible


--------------------------------------------------------------------------------
-- Distinguish certain kinds of guards

-- | An expression qualifies for a thetajoin predicate if both sides
-- are scalar expressions on exactly one of the join candidate
-- variables.
isThetaJoinPred :: Ident -> Ident -> Expr -> Bool
isThetaJoinPred x y (BinOp _ (SBRelOp _) e1 e2) =
    isFlatExpr e1 && isFlatExpr e1
    && ([x] == freeVars e1 && [y] == freeVars e2
        || [x] == freeVars e2 && [y] == freeVars e1)
isThetaJoinPred _ _ _ = False

-- | Does the predicate look like an existential quantifier?
isSemiJoinPred :: Ident -> Expr -> Bool
isSemiJoinPred x (AppE1 _ Or (Comp _ p
                                     (S (BindQ y _)))) = isThetaJoinPred x y p
isSemiJoinPred _  _                                    = False

-- | Does the predicate look like an universal quantifier?
isAntiJoinPred :: Ident -> Expr -> Bool
isAntiJoinPred x (AppE1 _ And (Comp _ p
                                      (S (BindQ y _)))) = isThetaJoinPred x y p
isAntiJoinPred _  _                                     = False

isFlatExpr :: Expr -> Bool
isFlatExpr expr =
    case expr of
        AppE1 _ (TupElem _) e -> isFlatExpr e
        UnOp _ _ e            -> isFlatExpr e
        BinOp _ _ e1 e2       -> isFlatExpr e1 && isFlatExpr e2
        Var _ _               -> True
        Lit _ _               -> True
        _                     -> False

--------------------------------------------------------------------------------
-- Computation of free variables

freeVarsT :: TransformC CL [Ident]
freeVarsT = fmap nub $ crushbuT $ promoteT $ do (ctx, Var _ v) <- exposeT
                                                guardM (v `freeIn` ctx)
                                                return [v]

-- | Compute free variables of the given expression
freeVars :: Expr -> [Ident]
freeVars = either error id . applyExpr freeVarsT

-- | Compute all identifiers bound by a qualifier list
compBoundVars :: F.Foldable f => f Qual -> [Ident]
compBoundVars = F.foldr aux []
  where
    aux :: Qual -> [Ident] -> [Ident]
    aux (BindQ n _) ns = n : ns
    aux (GuardQ _) ns  = ns

boundVarsT :: TransformC CL [Ident]
boundVarsT = fmap nub $ crushbuT $ promoteT $ readerT $ \expr -> case expr of
     Comp _ _ qs -> return $ compBoundVars qs
     Let _ v _ _ -> return [v]
     _           -> return []

-- | Compute all names that are bound in the given expression. Note
-- that the only binding forms in NKL are comprehensions or 'let'
-- bindings.
boundVars :: Expr -> [Ident]
boundVars = either error id . applyExpr boundVarsT

--------------------------------------------------------------------------------
-- Substitution

-- | /Exhaustively/ substitute term 's' for a variable 'v'.
substR :: Ident -> Expr -> RewriteC CL
substR v s = readerT $ \expr -> case expr of
    -- Occurence of the variable to be replaced
    ExprCL (Var _ n) | n == v                          -> return $ inject s

    -- If a let-binding shadows the name we substitute, only descend
    -- into the bound expression.
    ExprCL (Let _ n _ _)
        | n == v    -> tryR $ childR LetBind (substR v s)
        | otherwise -> if n `elem` freeVars s
                       -- If the let-bound name occurs free in the substitute,
                       -- alpha-convert the binding to avoid capturing the name.
                       then $unimplemented >>> tryR (anyR (substR v s))
                       else tryR $ anyR (substR v s)

    -- If some generator shadows v, we must not substitute in the comprehension
    -- head. However, substitute in the qualifier list. The traversal on
    -- qualifiers takes care of shadowing generators.
    -- FIXME in this case, rename the shadowing generator to avoid
    -- name-capturing (see lambda case)
    ExprCL (Comp _ _ qs) | v `elem` compBoundVars qs   -> tryR $ childR CompQuals (substR v s)
    ExprCL _                                           -> tryR $ anyR $ substR v s

    -- Don't substitute past shadowing generators
    QualsCL (BindQ n _ :* _) | n == v                  -> tryR $ childR QualsHead (substR v s)
    QualsCL _                                          -> tryR $ anyR $ substR v s
    QualCL _                                           -> tryR $ anyR $ substR v s


--------------------------------------------------------------------------------
-- Tuplifying variables

-- | Turn all occurences of two identifiers into accesses to one tuple variable.
-- tuplifyR z c y e = e[fst z/x][snd z/y]
tuplifyR :: Ident -> (Ident, Type) -> (Ident, Type) -> RewriteC CL
tuplifyR v (v1, t1) (v2, t2) = substR v1 v1Rep >+> substR v2 v2Rep
  where
    (v1Rep, v2Rep) = tupleVars v t1 t2

tupleVars :: Ident -> Type -> Type -> (Expr, Expr)
tupleVars n t1 t2 = (v1Rep, v2Rep)
  where v     = Var pt n
        pt    = PPairT t1 t2
        v1Rep = AppE1 t1 (TupElem First) v
        v2Rep = AppE1 t2 (TupElem (Next First)) v

--------------------------------------------------------------------------------
-- Helpers for combining generators with guards in a comprehensions'
-- qualifier list

-- | Insert a guard in a qualifier list at the first possible position.
-- 'insertGuard' expects the guard expression to insert, the initial name
-- envionment above the qualifiers and the list of qualifiers.
insertGuard :: Expr -> S.Set Ident -> NL Qual -> NL Qual
insertGuard guardExpr = go
  where
    go :: S.Set Ident -> NL Qual -> NL Qual
    go env (S q)                 =
        if all (`S.member` env) fvs
        then GuardQ guardExpr :* S q
        else q :* (S $ GuardQ guardExpr)
    go env (q@(BindQ x _) :* qs) =
        if all (`S.member` env) fvs
        then GuardQ guardExpr :* q :* qs
        else q :* go (S.insert x env) qs
    go env (GuardQ p :* qs)      =
        if all (`S.member` env) fvs
        then GuardQ guardExpr :* GuardQ p :* qs
        else GuardQ p :* go env qs

    fvs = freeVars guardExpr

------------------------------------------------------------------------
-- Generic iterator that merges guards into generators one by one.

-- | A container for the components of a comprehension expression
data Comp = C Type Expr (NL Qual)

fromQual :: Qual -> Either (Ident, Expr) Expr
fromQual (BindQ x e) = Left (x, e)
fromQual (GuardQ p)  = Right p


-- | Type of worker functions that merge guards into generators. It
-- receives the comprehension itself (with a qualifier list that
-- consists solely of generators), the current candidate guard
-- expression, guard expressions that have to be tried and guard
-- expressions that have been tried already. Last two are necessary if
-- the merging steps leads to tuplification.
type MergeGuard = Comp -> Expr -> [Expr] -> [Expr] -> TransformC () (Comp, [Expr], [Expr])

tryGuards :: MergeGuard  -- ^ The worker function
          -> Comp        -- ^ The current state of the comprehension
          -> [Expr]      -- ^ Guards to try
          -> [Expr]      -- ^ Guards that have been tried and failed
          -> TransformC () (Comp, [Expr])
-- Try the next guard
tryGuards mergeGuardR comp (p : ps) testedGuards = do
    let tryNextGuard :: TransformC () (Comp, [Expr])
        tryNextGuard = do
            -- Try to combine p with some generators
            (comp', ps', testedGuards') <- mergeGuardR comp p ps testedGuards

            -- On success, back out to give other rewrites
            -- (i.e. predicate pushdown) a chance.
            return (comp', ps' ++ testedGuards')

        -- If the current guard failed, try the next ones.
        tryOtherGuards :: TransformC () (Comp, [Expr])
        tryOtherGuards = tryGuards mergeGuardR comp ps (p : testedGuards)

    tryNextGuard <+ tryOtherGuards

-- No guards left to try and none succeeded
tryGuards _ _ [] _ = fail "no predicate could be merged"

-- | Try to build flat joins (equi-, semi- and antijoins) from a
-- comprehensions qualifier list.
-- FIXME only try on those predicates that look like equi-/anti-/semi-join predicates.
-- FIXME TransformC () ... is an ugly abuse of the rewrite system
mergeGuardsIterR :: MergeGuard -> RewriteC CL
mergeGuardsIterR mergeGuardR = do
    ExprCL (Comp ty e qs) <- idR

    -- Separate generators from guards
    (g : gs, guards@(_:_)) <- return $ partitionEithers $ map fromQual $ toList qs

    let initialComp = C ty e (uncurry BindQ <$> fromListSafe g gs)

    -- Try to merge one guard with some generators
    (C _ e' qs', remGuards) <- constT (return ())
                               >>> tryGuards mergeGuardR initialComp guards []

    -- If there are any guards remaining which we could not turn into
    -- joins, append them at the end of the new qualifier list
    case remGuards of
        rg : rgs -> let rqs = GuardQ <$> fromListSafe rg rgs
                    in return $ ExprCL $ Comp ty e' (appendNL qs' rqs)
        []       -> return $ ExprCL $ Comp ty e' qs'

--------------------------------------------------------------------------------
-- Traversal functions

-- | Traverse the spine of a NL list top-down and apply the translation as soon
-- as possible.
onetdSpineT
  :: (ReadPath c Int, MonadCatch m, Walker c CL)
  => Transform c m CL b
  -> Transform c m CL b
onetdSpineT t = do
    n <- idR
    case n of
        QualsCL (_ :* _) -> childT 0 t <+ childT 1 (onetdSpineT t)
        QualsCL (S _)    -> childT 0 t
        _                -> $impossible

--------------------------------------------------------------------------------
-- Classification of expressions

complexPrim2 :: Prim2 -> Bool
complexPrim2 _ = True

complexPrim1 :: Prim1 -> Bool
complexPrim1 op =
    case op of
        Concat    -> False
        TupElem _ -> False
        _         -> True

fromGuard :: Monad m => Qual -> m Expr
fromGuard (GuardQ e)  = return e
fromGuard (BindQ _ _) = fail "not a guard"

fromGen :: Monad m => Qual -> m (Ident, Expr)
fromGen (BindQ x xs) = return (x, xs)
fromGen (GuardQ _)   = fail "not a generator"

--------------------------------------------------------------------------------
-- Pattern synonyms for expressions

pattern ConcatP xs           <- AppE1 _ Concat xs
pattern SingletonP x         <- AppE1 _ Singleton x
pattern GuardP p             <- AppE1 _ Guard p
pattern SemiJoinP ty p xs ys <- AppE2 ty (SemiJoin p) xs ys
pattern AndP xs              <- AppE1 _ And xs
pattern NotP e               <- UnOp _ (SUBoolOp Not) e
pattern EqP e1 e2 <- BinOp _ (SBRelOp Eq) e1 e2
pattern LengthP e <- AppE1 _ Length e
pattern OrP xs <- AppE1 _ Or xs
pattern NullP e <- AppE1 _ Null e
pattern TrueP = Lit PBoolT (ScalarV (BoolV True))

