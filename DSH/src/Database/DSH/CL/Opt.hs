{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
    
-- | This module performs optimizations on the Comprehension Language (CL).
module Database.DSH.CL.Opt 
  ( opt 
  ) where
       
import           Debug.Trace
import           Text.Printf
                 
import           Control.Applicative((<$>), (<*>))
import           Control.Monad

import           Data.Generics.Uniplate.Data
                 
import qualified Data.Set as S

import           Database.DSH.Common.Data.Val
import           Database.DSH.Common.Data.Op
import           Database.DSH.Common.Data.Expr
import           Database.DSH.Common.Data.JoinExpr
import           Database.DSH.Common.Data.Type
import           Database.DSH.CL.Lang
       
-- We push simple filters which might end up in a theta join towards the front
-- of the qualifier list as far as possible.
pushFilters :: Expr -> Expr
pushFilters expr = transform go expr
  where go :: Expr -> Expr
        go (Comp t e qs) = Comp t e (reverse $ pushFromEnd $ reverse qs)
        go e             = e
        
        pushFromEnd :: [Qualifier] -> [Qualifier]
        pushFromEnd []                                    = []
        pushFromEnd ((GuardQ p) : qs) | isEquiJoinPred p = pushDown p (pushFromEnd qs)
        pushFromEnd (q : qs)                              = q : (pushFromEnd qs)
        
        pushDown :: Expr -> [Qualifier] -> [Qualifier]
        pushDown p []                                          = [GuardQ p]

        -- We push past other guards to get our join predicate as deep down as possible
        pushDown p (GuardQ p' : qs)                            = GuardQ p' : (pushDown p qs)

        -- We can't push past a generator on which the predicate depends
        pushDown p (BindQ x xs : qs) | x `S.member` freeVars p = (GuardQ p) : (BindQ x xs) : qs

        -- We push below generators if the predicate does not depend on it
        pushDown p (BindQ x xs : qs) | otherwise               = (BindQ x xs) : (pushDown p qs)
        
isEquiJoinPred :: Expr -> Bool
isEquiJoinPred (BinOp _ Eq e1 e2) = isProj e1 && isProj e2
isEquiJoinPred _                  = False

isProj :: Expr -> Bool
isProj (AppE1 _ (Prim1 Fst _) e) = isProj e
isProj (AppE1 _ (Prim1 Snd _) e) = isProj e
isProj (AppE1 _ (Prim1 Not _) e) = isProj e
isProj (BinOp _ _ e1 e2)         = isProj e1 && isProj e2
isProj (Var _ _)                 = True
isProj _                         = False
        
introduceEquiJoins :: Expr -> Expr
introduceEquiJoins expr = transform go expr
  where go :: Expr -> Expr
        go (Comp t e qs) = Comp t e' qs' where (e', qs') = buildJoins e qs
        go e             = e
        
        -- We traverse the qualifier list and look for an equi join pattern:
        -- [ e | qs, x <- xs, y <- ys, p, qs' ]
        -- = [ tuplify e x y | qs, x <- eqjoin p xs ys, tuplifyQuals qs' x y ]
        buildJoins :: Expr -> [Qualifier] -> (Expr, [Qualifier])
        buildJoins e qs = let (e', qs') = traverse e qs
                          in (e', qs')

        traverse :: Expr -> [Qualifier] -> (Expr, [Qualifier])
        traverse e [] = (e, [])
        traverse e (BindQ x xs : BindQ y ys : GuardQ p : qs) =
          case splitJoinPred p x y of
            Just (leftExpr, rightExpr) ->
              let xst     = typeOf xs
                  yst     = typeOf ys
                  xt      = elemT xst
                  yt      = elemT yst
                  pt      = listT $ pairT xt yt
                  jt      = xst .-> (yst .-> pt)
                  e'      = tuplify (x, xt) (y, yt) e
                  qs'     = tuplifyQuals (x, xt) (y, yt) qs
                  joinGen = BindQ x (AppE2 pt (Prim2 (EquiJoin leftExpr rightExpr) jt) xs ys)
               in traverse e' (joinGen : qs')
                  
            Nothing                    ->
              let (e', qs') = traverse e qs
              in  (e', BindQ x xs : BindQ y ys : GuardQ p : qs')
              
        traverse e (q : qs) =
          let (e', qs') = traverse e qs
          in  (e', q : qs')
        
        splitJoinPred :: Expr -> Ident -> Ident -> Maybe (JoinExpr, JoinExpr)
        splitJoinPred (BinOp _ Eq e1 e2) x y = 
          if isProj e1 && isProj e2
          then 
            case (S.elems $ freeVars e1, S.elems $ freeVars e2) of
              ([x'], [y']) | x == x' && y == y'  -> do
                je1 <- toJoinExpr e1 x
                je2 <- toJoinExpr e2 y
                return (je1, je2)
              ([y'], [x']) | x == x' && y == y' -> do
                je1 <- toJoinExpr e2 x
                je2 <- toJoinExpr e1 y
                return (je1, je2)
              _                                 -> mzero
          else Nothing

        splitJoinPred _ _ _               = mzero
        
        toJoinExpr :: Expr -> Ident -> Maybe JoinExpr
        toJoinExpr (AppE1 _ (Prim1 Fst _) e) x = UnOpJ FstJ <$> toJoinExpr e x
        toJoinExpr (AppE1 _ (Prim1 Snd _) e) x = UnOpJ SndJ <$> toJoinExpr e x
        toJoinExpr (AppE1 _ (Prim1 Not _) e) x = UnOpJ NotJ <$> toJoinExpr e x
        toJoinExpr (BinOp _ o e1 e2)         x = BinOpJ o <$> toJoinExpr e1 x <*> toJoinExpr e2 x
        toJoinExpr (Const _ v)               _ = return $ ConstJ v
        toJoinExpr (Var _ x') x | x == x'      = return InputJ
        toJoinExpr _                         _ = mzero
                                                    
            
opt :: Expr -> Expr
opt e = if (e /= e') 
        then trace (printf "%s\n---->\n%s" (show e) (show e')) e'
        else trace (show e) e'
  where e' = introduceEquiJoins $ pushFilters e