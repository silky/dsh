{-# LANGUAGE TemplateHaskell #-}

-- | This module provides the flattening implementation of DSH.
module Database.DSH.Flattening
  ( -- * Running queries via the Flattening backend
    fromQ
  , fromQX100
    -- * Debug functions
  , debugSQL
  , debugNKL
  , debugFKL
  , debugX100
  , debugCLX100
  , debugNKLX100
  , debugFKLX100
  , debugVL
  , debugX100VL
  , debugPFXML
  , dumpVLMem
  ) where

import           GHC.Exts
                 
import           Database.DSH.CompileFlattening
import           Database.DSH.ExecuteFlattening

import           Database.DSH.Internals
import           Database.HDBC
import qualified Database.HDBC                                   as H

import           Database.X100Client                             hiding (X100)
import qualified Database.X100Client                             as X

import           Database.Algebra.Dag

import           Database.DSH.Flattening.Common.Data.QueryPlan
import qualified Database.DSH.Flattening.Common.Data.Type        as T
import           Database.DSH.Flattening.Export
import qualified Database.DSH.Flattening.NKL.Data.NKL            as NKL
import qualified Database.DSH.Flattening.CL.Lang                 as CL
import qualified Database.DSH.Flattening.CL.Opt                  as CLOpt
import           Database.DSH.Flattening.Translate.Algebra2Query
import           Database.DSH.Flattening.Translate.CL2NKL
import           Database.DSH.Flattening.Translate.FKL2VL
import           Database.DSH.Flattening.Translate.NKL2FKL
import           Database.DSH.Flattening.Translate.VL2Algebra
import qualified Database.DSH.Flattening.VL.Data.Query           as Q

import           Data.Aeson                                      (encode)
import           Data.ByteString.Lazy.Char8                      (unpack)

import qualified Data.IntMap                                     as M
import qualified Data.List                                       as L

import           Control.Applicative
import           Control.Monad.State

import           Data.Convertible                                ()

(|>) :: a -> (a -> b) -> b
(|>) = flip ($)

-- Different versions of the flattening compiler pipeline

nkl2SQL :: CL.Expr -> (Q.Query Q.SQL, T.Type)
nkl2SQL e = let (e', t) = nkl2Alg e
            in (generateSQL e', t)

nkl2Alg :: CL.Expr -> (Q.Query Q.XML, T.Type)
nkl2Alg e = let q       = desugarComprehensions e
                          |> flatten
                          |> specializeVectorOps
                          |> implementVectorOpsPF
                          |> generatePFXML
                t       = T.typeOf e
            in (q, t)

nkl2X100Alg :: CL.Expr -> (Q.Query Q.X100, T.Type)
nkl2X100Alg e = let q = desugarComprehensions e
                        |> flatten
                        |> specializeVectorOps
                        |> implementVectorOpsX100
                        |> generateX100Query
                    t = T.typeOf e
                in (q, t)

nkl2X100File :: String -> CL.Expr -> IO ()
nkl2X100File prefix e = desugarComprehensions e
                        |> flatten
                        |> specializeVectorOps
                        |> implementVectorOpsX100
                        |> (exportX100Plan prefix)

nkl2SQLFile :: String -> CL.Expr -> IO ()
nkl2SQLFile prefix e = desugarComprehensions e
                       |> flatten
                       |> specializeVectorOps
                       |> implementVectorOpsPF
                       |> generatePFXML
                       |> generateSQL
                       |> (exportSQL prefix)

nkl2XMLFile :: String -> CL.Expr -> IO ()
nkl2XMLFile prefix e = desugarComprehensions e
                       |> flatten
                       |> specializeVectorOps
                       |> implementVectorOpsPF
                       |> generatePFXML
                       |> (exportPFXML prefix)

nkl2VLFile :: String -> CL.Expr -> IO ()
nkl2VLFile prefix e = desugarComprehensions e
                      |> flatten
                      |> specializeVectorOps
                      |> exportVLPlan prefix


-- Functions for executing and debugging DSH queries via the Flattening backend

-- | Compile a DSH query to SQL and run it on the database given by 'c'.
fromQ :: (QA a, IConnection conn) => conn -> Q a -> IO a
fromQ c (Q a) =  do
                   (q, _) <- nkl2SQL <$> toComprehensions (getTableInfo c) a
                   frExp <$> (executeSQLQuery c $ SQL q)

-- | Compile a DSH query to X100 algebra and run it on the X100 server given by 'c'.
fromQX100 :: QA a => X100Info -> Q a -> IO a
fromQX100 c (Q a) =  do
                  (q, _) <- nkl2X100Alg <$> toComprehensions (getX100TableInfo c) a
                  frExp <$> (executeX100Query c $ X100 q)
                  
-- | Debugging function: return the CL (Comprehension Language) representation of a
-- query (X100 version)
debugCLX100 :: QA a => X100Info -> Q a -> IO String
debugCLX100 c (Q e) = show <$> CLOpt.opt <$> toComprehensions (getX100TableInfo c) e

-- | Debugging function: return the NKL (Nested Kernel Language) representation of a
-- query (SQL version)
debugNKL :: (QA a, IConnection conn) => conn -> Q a -> IO String
debugNKL c (Q e) = show <$> toComprehensions (getTableInfo c) e

-- | Debugging function: return the NKL (Nested Kernel Language) representation of a
-- query (X100 version)
debugNKLX100 :: QA a => X100Info -> Q a -> IO String
debugNKLX100 c (Q e) = show <$> desugarComprehensions <$> toComprehensions (getX100TableInfo c) e

-- | Debugging function: return the FKL (Flat Kernel Language) representation of a
-- query (SQL version)
debugFKL :: (QA a, IConnection conn) => conn -> Q a -> IO String
debugFKL c (Q e) = show <$> flatten <$> desugarComprehensions <$> toComprehensions (getTableInfo c) e

-- | Debugging function: return the FKL (Flat Kernel Language) representation of a
-- query (X100 version)
debugFKLX100 :: QA a => X100Info -> Q a -> IO String
debugFKLX100 c (Q e) = show <$> flatten <$> desugarComprehensions <$> toComprehensions (getX100TableInfo c) e

-- | Debugging function: dumb the X100 plan (DAG) to a file.
debugX100 :: QA a => String -> X100Info -> Q a -> IO ()
debugX100 prefix c (Q e) = do
              e' <- toComprehensions (getX100TableInfo c) e
              nkl2X100File prefix e'

-- | Debugging function: dump the VL query plan (DAG) for a query to a file (SQL version).
debugVL :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugVL prefix c (Q e) = do
  e' <- toComprehensions (getTableInfo c) e
  nkl2VLFile prefix e'

-- | Debugging function: dump the VL query plan (DAG) for a query to a file (X100 version).
debugX100VL :: QA a => String -> X100Info -> Q a -> IO ()
debugX100VL prefix c (Q e) = do
  e' <- toComprehensions (getX100TableInfo c) e
  nkl2VLFile prefix e'

-- | Debugging function: dump the Pathfinder Algebra query plan (DAG) to XML files.
debugPFXML :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugPFXML prefix c (Q e) = do
  e' <- toComprehensions (getTableInfo c) e
  nkl2XMLFile prefix e'

-- | Debugging function: dump SQL queries generated by Pathfinder to files.
debugSQL :: (QA a, IConnection conn) => String -> conn -> Q a -> IO ()
debugSQL prefix c (Q e) = do
  e' <- toComprehensions (getTableInfo c) e
  nkl2SQLFile prefix e'

-- | Dump a VL plan in the JSON format expected by the in-memory implementation (Tobias Müller)
dumpVLMem :: QA a => FilePath -> X100Info -> Q a -> IO ()
dumpVLMem f c (Q q) = do
  cl <- toComprehensions (getX100TableInfo c) q
  let plan = desugarComprehensions cl
             |> flatten
             |> specializeVectorOps
      json = unpack $ encode (queryShape plan, M.toList $ nodeMap $ queryDag plan)
  writeFile f json

-- | Retrieve through the given database connection information on the table (columns with their types)
-- which name is given as the second argument.
getTableInfo :: IConnection conn => conn -> String -> IO [(String, (T.Type -> Bool))]
getTableInfo c n = do
                 info <- H.describeTable c n
                 return $ toTableDescr info

     where
       toTableDescr :: [(String, SqlColDesc)] -> [(String, (T.Type -> Bool))]
       toTableDescr = L.sortBy (\(n1, _) (n2, _) -> compare n1 n2) . map (\(name, props) -> (name, compatibleType (colType props)))
       compatibleType :: SqlTypeId -> T.Type -> Bool
       compatibleType dbT hsT = case hsT of
                                     T.UnitT -> True
                                     T.BoolT -> L.elem dbT [SqlSmallIntT, SqlIntegerT, SqlBitT]
                                     T.StringT -> L.elem dbT [SqlCharT, SqlWCharT, SqlVarCharT]
                                     T.IntT -> L.elem dbT [SqlSmallIntT, SqlIntegerT, SqlTinyIntT, SqlBigIntT, SqlNumericT]
                                     T.DoubleT -> L.elem dbT [SqlDecimalT, SqlRealT, SqlFloatT, SqlDoubleT]
                                     t       -> error $ "You can't store this kind of data in a table... " ++ show t ++ " " ++ show n

getX100TableInfo :: X100Info -> String -> IO [(String, (T.Type -> Bool))]
getX100TableInfo c n = do
                         t <- X.describeTable' c n
                         return [ col2Val col | col <- sortWith colName $ columns t]
        where
            col2Val :: ColumnInfo -> (String, T.Type -> Bool)
            col2Val col = (colName col, \t -> case logicalType col of
                                                LBool       -> t == T.BoolT || t == T.UnitT
                                                LInt1       -> t == T.IntT  || t == T.UnitT
                                                LUInt1      -> t == T.IntT  || t == T.UnitT
                                                LInt2       -> t == T.IntT  || t == T.UnitT
                                                LUInt2      -> t == T.IntT  || t == T.UnitT
                                                LInt4       -> t == T.IntT  || t == T.UnitT
                                                LUInt4      -> t == T.IntT  || t == T.UnitT
                                                LInt8       -> t == T.IntT  || t == T.UnitT
                                                LUInt8      -> t == T.IntT  || t == T.UnitT
                                                LInt16      -> t == T.IntT  || t == T.UnitT
                                                LUIDX       -> t == T.NatT  || t == T.UnitT
                                                LDec        -> t == T.DoubleT
                                                LFlt4       -> t == T.DoubleT
                                                LFlt8       -> t == T.DoubleT
                                                LMoney      -> t == T.DoubleT
                                                LChar       -> t == T.StringT
                                                LVChar      -> t == T.StringT
                                                LDate       -> t == T.IntT
                                                LTime       -> t == T.IntT
                                                LTimeStamp  -> t == T.IntT
                                                LIntervalDS -> t == T.IntT
                                                LIntervalYM -> t == T.IntT
                                                LUnknown s  -> error $ "Unknown DB type" ++ show s)

