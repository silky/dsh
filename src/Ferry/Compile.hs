{-# LANGUAGE ScopedTypeVariables, TemplateHaskell #-}
module Ferry.Compile where
    
import Ferry.Pathfinder
import Ferry.Data
import Ferry.Impossible

import qualified Data.Map as M
import Data.Maybe (fromJust, isNothing, isJust)
import Data.List (sortBy)
import Control.Monad.Reader

import Text.XML.HaXml as X

import Database.HDBC
import Data.Convertible.Base

import System.IO.Unsafe

newtype AlgebraXML a = Algebra String

newtype SQLXML a = SQL String
 deriving Show
 
newtype QueryBundle a = Bundle [(Int, (String, SchemaInfo, Maybe Int, Maybe Int))]

data SchemaInfo = SchemaInfo {iter :: String, items :: [(String, Int)]}

data ResultInfo = ResultInfo {iterR :: Int, resCols :: [(String, Int)]}

executePlan :: forall a. forall conn. (QA a, IConnection conn) => conn -> AlgebraXML a -> IO Norm
executePlan c p@(Algebra plan) = do 
                        sql@(SQL sqlll) <- (unsafePerformIO $ putStrLn plan) `seq` algToSQL p
                        let plan = (unsafePerformIO $ putStrLn sqlll) `seq` extractSQL sql
                        runSQL c plan
 
algToSQL :: AlgebraXML a -> IO (SQLXML a)
algToSQL (Algebra s) = do
                         r <- compileFerryOpt s OutputSql Nothing 
                         case r of
                            (Right sql) -> return $ SQL sql
                            (Left err) -> error $ "Pathfinder compilation for input: \n"
                                                    ++ s ++ "\n failed with error: \n"
                                                    ++ err

extractSQL :: SQLXML a -> QueryBundle a 
extractSQL (SQL x) = let (Document _ _ r _) = xmlParse "query" x
                      in Bundle $ map extractQuery $ (deep $ tag "query_plan") (CElem r undefined)
    where
        extractQuery c@(CElem (X.Elem n attrs cs) _) = let qId = case fmap attrToInt $ lookup "id" attrs of
                                                                    Just x -> x
                                                                    Nothing -> $impossible
                                                           rId = fmap attrToInt $ lookup "idref" attrs
                                                           cId = fmap ((1+) . attrToInt) $ lookup "colref" attrs
                                                           query = extractCData $  head $ concatMap children $ deep (tag "query") c
                                                           schema = toSchemeInf $ map process $ concatMap children $ deep (tag "schema") c
                                                        in (qId, (query, schema, rId, cId))
        attrToInt :: AttValue -> Int
        attrToInt (AttValue [(Left i)]) = read i
        attrToString :: AttValue -> String
        attrToString (AttValue [(Left i)]) = i
        extractCData :: Content i -> String
        extractCData (CString _ d _) = d
        toSchemeInf :: [(String, Maybe Int)] -> SchemaInfo
        toSchemeInf results = let iterN = fst $ head $ filter (\(_, p) -> isNothing p) results
                                  cols = map (\(n, v) -> (n, fromJust v)) $ filter (\(_, p) -> isJust p) results
                               in SchemaInfo iterN cols
        process :: Content i -> (String, Maybe Int)
        process (CElem (X.Elem _ attrs _) _) = let name = case fmap attrToString $ lookup "name" attrs of
                                                                    Just x -> x
                                                                    Nothing -> $impossible
                                                   pos = fmap attrToInt $ lookup "position" attrs
                                                in (name, pos)
        
runSQL :: forall a. forall conn. (QA a, IConnection conn) => conn -> QueryBundle a -> IO Norm
runSQL c (Bundle queries) = do
                             results <- mapM (runQuery c) queries
                             let (queryMap, valueMap) = foldr buildRefMap ([],[]) results
                             let ty = reify (undefined :: a)
                             let results = runReader (processResults 0 ty) (queryMap, valueMap) 
                             return $ snd $ head results
                             
type QueryR = Reader ([((Int, Int), Int)] ,[(Int, ([[SqlValue]], ResultInfo))])


getResults :: Int -> QueryR [[SqlValue]] 
getResults i = do
                env <- ask
                return $ case lookup i $ snd env of
                              Just x -> fst x
                              Nothing -> $impossible

getIterCol :: Int -> QueryR Int
getIterCol i = do
                env <- ask
                return $ case lookup i $ snd env of
                            Just x -> iterR $ snd x
                            Nothing -> $impossible
                
findQuery :: (Int, Int) -> QueryR Int
findQuery i = do
                env <- ask
                return $ fromJust $ lookup i $ fst env

processResults :: Int -> Type -> QueryR [(Int, Norm)]
processResults i (ListT t1) = do
                                v <- getResults i
                                itC <- getIterCol i
                                let partedVals = partByIter itC v
                                mapM (\(it, vals) -> do
                                                        v1 <- processResults' i 1 vals t1
                                                        return (it, ListN v1)) partedVals
processResults i t = do
                        v <- getResults i
                        itC <- getIterCol i
                        let partedVals = partByIter itC v
                        mapM (\(it, vals) -> do
                                              v1 <- processResults' i 1 vals t
                                              return (it, head v1)) partedVals

                            
processResults' :: Int -> Int -> [[SqlValue]] -> Type -> QueryR [Norm]
processResults' _ _ vals BoolT = return $ map (\[val1] -> BoolN $ convert val1) vals
processResults' _ _ vals UnitT = return $ map (\[_] -> UnitN) vals
processResults' _ _ vals IntegerT = return $ map (\[val1] -> IntegerN $ convert val1) vals
processResults' _ _ vals DoubleT = return $ map (\[val1] -> DoubleN $ convert val1) vals
processResults' q c vals (TupleT t1 t2) = mapM (\(val1:vs) -> do
                                                                v1 <- processResults' q c [[val1]] t1
                                                                v2 <- processResults' q (c + 1) [vs] t2
                                                                return $ TupleN (head v1) (head v2)) vals
processResults' q c vals (ListT t) = do
                                        nestQ <- findQuery (q, c)
                                        list <- processResults nestQ t
                                        return undefined
                                        
                            
partByIter :: Int -> [[SqlValue]] -> [(Int, [[SqlValue]])]
partByIter n v = M.toList $ foldr (iterMap n) M.empty v

iterMap :: Int -> [SqlValue] -> M.Map Int [[SqlValue]] -> M.Map Int [[SqlValue]]
iterMap n xs m = let x = xs !! n
                     iter = ((fromSql x)::Int)
                     vals = case M.lookup iter m of
                                    Just vs  -> vs
                                    Nothing -> []
                  in M.insert iter (xs:vals) m

runQuery :: IConnection conn => conn -> (Int, (String, SchemaInfo, Maybe Int, Maybe Int)) -> IO (Int, ([[SqlValue]], ResultInfo, Maybe Int, Maybe Int))
runQuery c (qId, (query, schema, rId, cId)) = do
                                                sth <- prepare c query
                                                _ <- execute sth []
                                                res <- fetchAllRows' sth
                                                resDescr <- describeResult sth
                                                return $ (unsafePerformIO $ do
                                                                             putStrLn query
                                                                             putStrLn $ show resDescr
                                                                             putStrLn $ show res) `seq` (qId, (res, schemeToResult schema resDescr, rId, cId))

schemeToResult :: SchemaInfo -> [(String, SqlColDesc)] -> ResultInfo 
schemeToResult (SchemaInfo itN cols) resDescr = let ordCols = sortBy (\(_, c1) (_, c2) -> compare c1 c2) cols
                                                    resCols = flip zip [0..] $ map (\(c, _) -> takeWhile (\a -> a /= '_') c) resDescr
                                                    itC = fromJust $ lookup itN resCols
                                                 in ResultInfo itC $ map (\(n, _) -> (n, fromJust $ lookup n resCols)) ordCols

buildRefMap :: (Int, ([[SqlValue]], ResultInfo, Maybe Int, Maybe Int)) -> ([((Int, Int), Int)] ,[(Int, ([[SqlValue]], ResultInfo))]) -> ([((Int, Int), Int)] ,[(Int, ([[SqlValue]], ResultInfo))])
buildRefMap (q, (r, ri, (Just t), (Just c))) (qm, rm) = (((t, c), q):qm, (q, (r, ri)):rm)
buildRefMap (q, (r, ri, _, _)) (qm, rm) = (qm, (q, (r, ri)):rm)

