{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Frontend.TupleTypes where

import           Control.Applicative
import           Data.List
import           Text.Printf

import           Language.Haskell.TH

import           Database.DSH.Common.Nat
import qualified Database.DSH.CL.Primitives as CP

--------------------------------------------------------------------------------
-- Tuple Accessors

-- | Generate all constructors for a given tuple width.
mkTupElemCons :: Name -> Name -> Int -> Q [Con]
mkTupElemCons aTyVar bTyVar width = do
    boundTyVars <- mapM (\i -> newName $ printf "t%d" i) [1..width-1]
    mapM (mkTupElemCon aTyVar bTyVar boundTyVars width) [1..width]

mkTupType :: Int -> Int -> [Name] -> Name -> Type
mkTupType elemIdx width boundTyVars bTyVar =
    let elemTys = map VarT $ take (elemIdx - 1) boundTyVars 
                             ++ [bTyVar] 
                             ++ drop (elemIdx - 1) boundTyVars
    in foldl' AppT (TupleT width) elemTys

conName :: Int -> Int -> Name
conName width elemIdx = mkName $ printf "Tup%d_%d" width elemIdx
    
mkTupElemCon :: Name -> Name -> [Name] -> Int -> Int -> Q Con
mkTupElemCon aTyVar bTyVar boundTyVars width elemIdx = do
    let binders   = map PlainTV boundTyVars
    let tupleType = mkTupType elemIdx width boundTyVars bTyVar
    let con       = conName width elemIdx
    let ctx       = [EqualP (VarT aTyVar) tupleType]
    return $ ForallC binders ctx (NormalC con [])

-- | Generate the complete type of tuple acccessors for all tuple
-- widths.
-- 
-- @
-- data TupElem a b where 
--     Tup2_1 :: TupElem (a, b) a 
--     Tup2_2 :: TupElem (a, b) b 
--     Tup3_1 :: TupElem (a, b, c) a 
--     Tup3_2 :: TupElem (a, b, c) b 
--     Tup3_3 :: TupElem (a, b, c) c 
--     ...
-- @
-- 
-- Due to the lack of support for proper GADT syntax in TH, we have
-- to work with explicit universal quantification:
-- 
-- @
-- data TupElem a b =
--     | forall d. a ~ (b, d) => Tup2_1
--     | forall d. a ~ (d, b) => Tup2_2
-- 
--     | forall d e. a ~ (b, d, e) => Tup3_1
--     | forall d e. a ~ (d, b, e) => Tup3_2
--     | forall d e. a ~ (d, e, b) => Tup3_3
--     ...
-- @
mkTupElemType :: Int -> Q [Dec]
mkTupElemType maxWidth = do
    let tyName = mkName "TupElem"

    aTyVar <- newName "a"
    bTyVar <- newName "b"
    let tyVars = map PlainTV [aTyVar, bTyVar]

    cons   <- concat <$> mapM (mkTupElemCons aTyVar bTyVar) [2..maxWidth]

    return $ [DataD [] tyName tyVars cons []]
 
--------------------------------------------------------------------------------
-- Translation of tuple accessors to CL

mkCompileMatch :: Name -> (Name, Int) -> Q Match
mkCompileMatch exprName (con, elemIdx) = do
    let translateVar = return $ VarE $ mkName "translate"
        exprVar      = return $ VarE exprName
        idxLit       = return $ LitE $ IntegerL $ fromIntegral elemIdx
    bodyExp  <- [| CP.tupElem (intIndex $idxLit) <$> $translateVar $exprVar |]
    let body = NormalB $ bodyExp
    return $ Match (ConP con []) body []

mkTupElemCompile :: Int -> Q Exp
mkTupElemCompile maxWidth = do
    let cons = concat [ [ (conName width idx, idx)
                        | idx <- [1..width] 
                        ] 
                      | width <- [2..maxWidth] 
                      ]

    exprName <- newName "e"
    opName   <- newName "te"

    matches  <- mapM (mkCompileMatch exprName) cons

    let lamBody = CaseE (VarE opName) matches
    return $ LamE [VarP opName, VarP exprName] lamBody

--------------------------------------------------------------------------------
-- Reify instances for tuple types

reifyType :: Name -> Exp
reifyType tyName = AppE (VarE $ mkName "reify") (SigE (VarE 'undefined) (VarT tyName))

mkReifyFun :: [Name] -> Dec
mkReifyFun tyNames =
    let argTys         = map reifyType tyNames
        tupTyConstName = mkName $ printf "Tuple%dT" (length tyNames)
        body           = AppE (ConE $ mkName "TupleT") (foldl' AppE (ConE tupTyConstName) argTys)
    in FunD (mkName "reify") [Clause [WildP] (NormalB body) []]

mkReifyInstance :: Int -> Dec
mkReifyInstance width =
    let tyNames  = map (\i -> mkName $ "t" ++ show i) [1..width]
        tupTy    = foldl' AppT (TupleT width) $ map VarT tyNames
        instTy   = AppT (ConT $ mkName "Reify") tupTy
        reifyCxt = map (\tyName -> ClassP (mkName "Reify") [VarT tyName]) tyNames
        
    in InstanceD reifyCxt instTy [mkReifyFun tyNames]

mkReifyInstances :: Int -> Q [Dec]
mkReifyInstances maxWidth = return $ map mkReifyInstance [2..maxWidth]
