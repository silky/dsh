{-# LANGUAGE TemplateHaskell #-}
module Ferry.QQ2 (qc, fp, rw, module Ferry.Combinators) where

import Ferry.Impossible

import qualified Ferry.Combinators
import qualified Language.Haskell.TH as TH
import Language.Haskell.TH.Quote
import Language.Haskell.Exts.Parser
import Language.Haskell.Exts.Syntax
import Language.Haskell.SyntaxTrees.ExtsToTH
import Language.Haskell.Exts.Extension
import Language.Haskell.Exts.Build
import Language.Haskell.Exts.Pretty

import Control.Monad
import Control.Monad.State 
import Control.Applicative

import Data.Generics

import qualified Data.Set as S
import qualified Data.List as L

type N = State Int

instance Applicative (State s) where
  pure  = return
  (<*>) = ap

freshVar :: N String
freshVar = do
             i <- get
             put (i + 1)
             return $ "Ferry.FreshNames.v" ++ show i
     
runN :: N a -> a
runN = fst . flip runState 1

quoteListCompr :: String -> TH.ExpQ
quoteListCompr = transform . parseCompr

quoteListComprPat :: String -> TH.PatQ
quoteListComprPat = undefined

transform :: Exp -> TH.ExpQ
transform e = case translateExtsToTH . runN $ translateListCompr e of
                Left err -> error $ show err
                Right e1 -> return e1

parseCompr :: String -> Exp
parseCompr = fromParseResult . exprParser

exprParser :: String -> ParseResult Exp
exprParser = parseExpWithMode (defaultParseMode {extensions = [TransformListComp, ViewPatterns]}) . expand

expand :: String -> String
expand e = '[':(e ++ "]")

ferryHaskell :: QuasiQuoter
ferryHaskell = QuasiQuoter quoteListCompr quoteListComprPat

qc :: QuasiQuoter
qc = ferryHaskell

fp :: QuasiQuoter
fp = QuasiQuoter (return . TH.LitE . TH.StringL . show . parseCompr) undefined

rw :: QuasiQuoter
rw = QuasiQuoter (return . TH.LitE . TH.StringL . prettyPrint . runN . translateListCompr . parseCompr) undefined

translateListCompr :: Exp -> N Exp
translateListCompr (ListComp e q) = do
                                     let pat = variablesFromLst $ reverse q
                                     pat' <- mkViewPat pat 
                                     lambda <- makeLambda pat' (SrcLoc "" 0 0) e
                                     (mapF lambda) <$> normaliseQuals q
translateListCompr l              = error $ "Expr not supported by Ferry: " ++ show l

-- Transforming qualifiers

normaliseQuals :: [QualStmt] -> N Exp
normaliseQuals = normaliseQuals' . reverse

normaliseQuals' :: [QualStmt] -> N Exp
normaliseQuals' [q]    = normaliseQual q
normaliseQuals' []     = pure $ consF unit nilF
normaliseQuals' (q:ps) = do
                          qn <- normaliseQual q
                          let qv = variablesFrom q
                          pn <- normaliseQuals' ps
                          let pv = variablesFromLst ps
                          combine pn pv qn qv
                          
normaliseQual :: QualStmt -> N Exp
normaliseQual (QualStmt (Generator _ _ e)) = pure $ e
normaliseQual (QualStmt (Qualifier e)) = pure $ boolF (consF unit nilF) nilF e

combine :: Exp -> Pat -> Exp -> Pat -> N Exp
combine p pv q qv = do
                     qv' <- mkViewPat qv
                     pv' <- mkViewPat pv
                     qLambda <- makeLambda qv' (SrcLoc "" 0 0) $ pairF (patToExp qv) $ patToExp pv
                     pLambda <- makeLambda pv' (SrcLoc "" 0 0) $ mapF qLambda q
                     pure $ concatF (mapF pLambda p)
                     
makeLambda :: Pat -> SrcLoc -> Exp -> N Exp
makeLambda p s b = pure $ Lambda s [p] b

-- Building and converting patterns

variablesFromLst :: [QualStmt] -> Pat
variablesFromLst [x]    = variablesFrom x
variablesFromLst (x:xs) = PTuple [variablesFrom x, variablesFromLst xs]
variablesFromLst []     = PWildCard

variablesFrom :: QualStmt -> Pat
variablesFrom (QualStmt (Generator _ p _)) = p
variablesFrom (QualStmt (Qualifier _)) = PWildCard
variablesFrom (QualStmt (LetStmt (BDecls [PatBind _ p _ _ _]))) = p
variablesFrom (QualStmt e)  = error $ "Not supported yet: " ++ show e
variablesFrom _ = $impossible

mkViewPat :: Pat -> N Pat
mkViewPat p@(PVar _)  = return $ p
mkViewPat PWildCard   = return $ PWildCard
mkViewPat (PTuple ps) = (\x -> PViewPat viewV $ PTuple x) <$> mapM mkViewPat ps
mkViewPat (PList ps)  = (\x -> PViewPat viewV $ PList x) <$> mapM mkViewPat ps
mkViewPat (PParen p)  = PParen <$> mkViewPat p
mkViewPat p           = pure $ PViewPat viewV p 

viewV :: Exp
viewV = var $ name $ "view"
{-
viewF :: Pat -> Exp -> Exp
viewF p e = Lambda Case 
-}
patToExp :: Pat -> Exp
patToExp (PVar x)                    = var x
patToExp (PTuple [x, y])             = pairF (patToExp x) $ patToExp y
patToExp (PApp (Special UnitCon) []) = unit
patToExp PWildCard                   = unit
patToExp p                           = error $ "Pattern not suppoted by ferry: " ++ show p

-- Ferry Combinators

mapV :: Exp
mapV = var $ name "Ferry.Combinators.map"

mapF :: Exp -> Exp -> Exp
mapF f l = flip app l $ app mapV f

unit :: Exp
unit = var $ name "Ferry.Combinators.unit"

consF :: Exp -> Exp -> Exp
consF hd tl = flip app tl $ app consV hd

nilF :: Exp
nilF = nilV

nilV :: Exp
nilV = var $ name "Ferry.Combinators.nil"

consV :: Exp
consV = var $ name "Ferry.Combinators.cons"

pairV :: Exp
pairV = var $ name "Ferry.Combinators.pair"

pairF :: Exp -> Exp -> Exp
pairF e1 e2 = flip app e2 $ app pairV e1

concatF :: Exp -> Exp
concatF = app concatV

concatV :: Exp
concatV = var $ name "Ferry.Combinators.concat"

boolF :: Exp -> Exp -> Exp -> Exp
boolF t e c = app (app ( app (var $ name "Ferry.Combinators.bool") t) e) c 