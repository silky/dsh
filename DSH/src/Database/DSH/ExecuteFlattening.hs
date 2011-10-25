{-# LANGUAGE ScopedTypeVariables, TemplateHaskell, ParallelListComp, TransformListComp, FlexibleInstances, MultiParamTypeClasses #-}
module Database.DSH.ExecuteFlattening where

import qualified Language.ParallelLang.DBPH as P
import qualified Language.ParallelLang.Common.Data.Type as T

import Database.DSH.Data
import Database.DSH.Impossible

import Database.X100Client hiding (X100 (..))

import Database.HDBC

import Control.Exception (evaluate)
import Control.Monad(liftM)

import GHC.Exts

import Data.Convertible
import Data.Text (pack)
import qualified Data.Text as Txt
import Data.List (foldl')
import Data.Maybe (fromJust)


data SQL a = SQL (P.Query P.SQL)

data X100 a = X100 (P.Query P.X100)

fromFType :: T.Type -> Type
fromFType (T.Var _) = $impossible
fromFType (T.Fn _ _)  = $impossible
fromFType (T.Int)   = IntegerT
fromFType (T.Bool)  = BoolT
fromFType (T.Double) = DoubleT
fromFType (T.String) = TextT
fromFType (T.Unit) = UnitT
fromFType (T.Nat) = IntegerT
fromFType (T.Pair e1 e2) = TupleT (fromFType e1) (fromFType e2)  
fromFType (T.List t) = ListT (fromFType t)

typeReconstructor :: Type -> Type -> (Type, Norm -> Norm)
typeReconstructor o ex | o == ex = (o, id)
                       | o == TextT && ex == CharT = (ex, textToChar) 
                       | otherwise = case ex of
                                        ListT _ -> let (t1, f1) = pushIn ex
                                                       (t2, f2) = typeReconstructor o t1
                                                    in (t2, f1 . f2)
                                        TupleT t1 t2 -> case o of
                                                         TupleT to1 to2 -> let r1@(t1',_) = typeReconstructor to1 t1
                                                                               r2@(t2',_) = typeReconstructor to2 t2
                                                                            in (TupleT t1' t2', onPair r1 r2)
                                                         _ -> error "cannot reconstruct type"
                                        CharT -> (CharT, textToChar)
                                        t -> error $ "This type cannot be reconstructed: " ++ show t ++ " provided: " ++ show o

textToChar :: Norm -> Norm
textToChar (TextN t TextT) = CharN (Txt.head t) CharT 
textToChar _               = error $ "textToChar: Not a char value"

onPair :: (Type, Norm -> Norm) -> (Type, Norm -> Norm) -> Norm -> Norm
onPair (t1, f1) (t2, f2) (TupleN e1 e2 _) = TupleN (f1 e1) (f2 e2) (TupleT t1 t2) 
onPair _ _ _ = error "onPair: Not a pair value"  
                                                         
pushIn :: Type -> (Type, Norm -> Norm)
pushIn (ListT (TupleT e1 e2)) = (TupleT (ListT e1) (ListT e2), zipN)
pushIn ty@(ListT v@(ListT _)) = let (t, f) = pushIn v
                                 in (ListT t, mapN (ty, f))
pushIn t = (t, id)
                      
mapN :: (Type, Norm -> Norm) -> Norm -> Norm
mapN (t, f) (ListN es _) = ListN (map f es) t
mapN (t, _) v = error $ "This can't be: " ++ show t ++ "\n" ++ show v
                                      
retuple :: Type -> Type -> Norm -> Norm
retuple t te v = let (_, f) = typeReconstructor t te
                  in f v

zipN :: Norm -> Norm
zipN (TupleN (ListN es1 (ListT t1)) (ListN es2 (ListT t2)) _) = ListN [TupleN e1 e2 (TupleT t1 t2) | e1 <- es1 | e2 <- es2] (ListT (TupleT t1 t2))
zipN e = error $ "zipN: " ++ show e -- $impossible

executeSQLQuery :: forall a. forall conn. (QA a, IConnection conn) => conn -> T.Type -> SQL a -> IO a
executeSQLQuery c vt (SQL q) = do
                                let et = reify (undefined :: a)
                                let gt = fromFType vt
                                n <- makeNormSQL c q (fromFType vt)
                                return $ fromNorm $ retuple gt et $ fromEither (fromFType vt) n

executeX100Query :: forall a. QA a => X100Info -> T.Type -> X100 a -> IO a
executeX100Query c vt (X100 q) = do
                                  let et = reify (undefined :: a)
                                  let gt = fromFType vt
                                  n <- makeNormX100 c q (fromFType vt)
                                  return $ fromNorm $ retuple gt et $ fromEither (fromFType vt) n

makeNormSQL :: IConnection conn => conn -> P.Query P.SQL -> Type -> IO (Either Norm [(Int, Norm)])
makeNormSQL c (P.PrimVal (P.SQL _ s q)) t = do
                                          (r, d) <- doSQLQuery c q
                                          let (iC, ri) = schemeToResult s d
                                          let [(_, [(_, v)])] = partByIter iC r
                                          let i = snd (fromJust ri)
                                          return $ Left $ normalise t i v
makeNormSQL c (P.ValueVector (P.SQL _ s q)) t = do
                                               (r, d) <- doSQLQuery c q
                                               let (iC, ri) = schemeToResult s d
                                               let parted = partByIter iC r
                                               let i = snd (fromJust ri)
                                               return $ Right $ normaliseList t i parted
makeNormSQL c (P.TupleVector [q1, q2]) t@(TupleT t1 t2) = do
                                                         r1 <- liftM (fromEither t1) $ makeNormSQL c q1 t1
                                                         r2 <- liftM (fromEither t2) $ makeNormSQL c q2 t2
                                                         return $ Left $ TupleN r1 r2 t
makeNormSQL c (P.NestedVector (P.SQL _ s q) qr) t@(ListT t1) = do
                                                             (r, d) <- doSQLQuery c q
                                                             let (iC, _) = schemeToResult s d
                                                             let parted = partByIter iC r
                                                             inner <- (liftM fromRight) $ makeNormSQL c qr t1
                                                             return $ Right $ constructDescriptor t (map (\(i, p) -> (i, map fst p)) parted) inner
makeNormSQL _c v t = error $ "Val: " ++ show v ++ "\nType: " ++ show t

makeNormX100 :: X100Info -> P.Query P.X100 -> Type -> IO (Either Norm [(Int, Norm)])
makeNormX100 c (P.PrimVal (P.X100 _ q)) t = do
                                              (X100Res cols res) <- doX100Query c q
                                              let [(_, [(_, Just v)])] = partByIterX100 res
                                              return $ Left $ normaliseX100 t v
makeNormX100 c (P.ValueVector (P.X100 _ q)) t = do
                                                (X100Res cols res) <- doX100Query c q
                                                let parted = partByIterX100 res
                                                return $ Right $ normaliseX100List t parted
makeNormX100 c (P.TupleVector [q1, q2]) t@(TupleT t1 t2) = do
                                                            r1 <- liftM (fromEither t1) $ makeNormX100 c q1 t1
                                                            r2 <- liftM (fromEither t2) $ makeNormX100 c q2 t2
                                                            return $ Left $ TupleN r1 r2 t
makeNormX100 c (P.NestedVector (P.X100 _ q) qr) t@(ListT t1) = do
                                                                (X100Res cols res) <- doX100Query c q
                                                                let parted = partByIterX100 res
                                                                inner <- (liftM fromRight) $ makeNormX100 c qr t1
                                                                return $ Right $ constructDescriptor t (map (\(i, p) -> (i, map fst p)) parted) inner

fromRight :: Either a b -> b
fromRight (Right x) = x
fromRight _         = error "fromRight"

fromEither :: Type -> Either Norm [(Int, Norm)] -> Norm
fromEither _ (Left n) = n
fromEither t (Right ns) = concatN t $ reverse $ map snd ns 

constructDescriptor :: Type -> [(Int, [Int])] -> [(Int, Norm)] -> [(Int, Norm)]
constructDescriptor t@(ListT t1) ((i, vs):outers) inners = let (r, inners') = nestList t1 vs inners
                                                            in (i, ListN r t) : constructDescriptor t outers inners'
constructDescriptor _            []               _      = []
constructDescriptor _ _ _ = error "constructDescriptor: type not a list"


nestList :: Type -> [Int] -> [(Int, Norm)] -> ([Norm], [(Int, Norm)])
nestList t ps'@(p:ps) ls@((d,n):lists) | p == d = n `combine` (nestList t ps lists)
                                       | p <  d = ListN [] t `combine` (nestList t ps ls)
                                       | p >  d = nestList t ps' lists
nestList t (p:ps)     []                         = ListN [] t `combine` (nestList t ps [])
nestList t []         ls                         = ([], ls) 
nestList _ _ _ = error "nestList $ Not a neted list"

combine :: Norm -> ([Norm], [(Int, Norm)]) -> ([Norm], [(Int, Norm)])
combine n (ns, r) = (n:ns, r)


concatN :: Type -> [Norm] -> Norm
concatN _ ns@((ListN ls t1):_) = foldl' (\(ListN e t) (ListN e1 _) -> ListN (e1 ++ e) t) (ListN [] t1) ns
concatN t []                   = ListN [] t
concatN _ _                    = error "concatN: Not a list of lists"

normaliseList :: Type -> Int -> [(Int, [(Int, [SqlValue])])] -> [(Int, Norm)]
normaliseList t@(ListT t1) c vs = reverse $ foldl' (\tl (i, v) -> (i, ListN (map ((normalise t1 c) . snd) v) t):tl) [] vs
normaliseList _            _ _  = error "normaliseList: Should not happen"

normaliseX100List :: Type -> [(Int, [(Int, Maybe X100Data)])] -> [(Int, Norm)]
normaliseX100List t@(ListT t1) vs = reverse $ foldl' (\tl (i, v) -> (i, ListN (map ((normaliseX100 t1) . fromJust . snd) v) t):tl) [] vs
normaliseX100List _ _ = error "normaliseX100List: Should not happen"

normalise :: Type -> Int -> [SqlValue] -> Norm
normalise UnitT _ _ = UnitN UnitT
normalise t i v = convert (v !! i, t)

normaliseX100 :: Type -> X100Data -> Norm
normaliseX100 UnitT _ = UnitN UnitT
normaliseX100 t v = convert (v, t)

instance Convertible (X100Data, Type) Norm where
    safeConvert (Str s, TextT) = Right $ TextN (pack s) TextT
    safeConvert (Str s, CharT) = Right $ CharN (head s) CharT
    safeConvert (UChr i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (SChr i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (SInt i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (UInt i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (SSht i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (USht i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (SLng i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (ULng i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (UIDX i, BoolT) = Right $ BoolN (i /= 0) BoolT
    safeConvert (SInt i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (UInt i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (SChr i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (UChr i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (SSht i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (USht i, IntegerT) = Right $ IntegerN (toInteger i) IntegerT
    safeConvert (SLng i, IntegerT) = Right $ IntegerN i IntegerT
    safeConvert (ULng i, IntegerT) = Right $ IntegerN i IntegerT
    safeConvert (UIDX i, IntegerT) = Right $ IntegerN i IntegerT
    safeConvert (Dbl d, DoubleT) = Right $ DoubleN d DoubleT
    safeConvert _                = error $ "cannot convert (X100Data, Type) to Norm"

doSQLQuery :: IConnection conn => conn -> String -> IO ([[SqlValue]], [(String, SqlColDesc)])
doSQLQuery c q = do
                sth <- prepare c q
                _ <- execute sth []
                res <- dshFetchAllRowsStrict sth
                resDescr <- describeResult sth
                return (res, resDescr)

doX100Query :: X100Info -> String -> IO X100Result
doX100Query c q = executeQuery c q
                
dshFetchAllRowsStrict :: Statement -> IO [[SqlValue]]
dshFetchAllRowsStrict stmt = go []
  where
  go :: [[SqlValue]] -> IO [[SqlValue]]
  go acc = do  mRow <- fetchRow stmt
               case mRow of
                 Nothing   -> return (reverse acc)
                 Just row  -> do mapM_ evaluate row
                                 go (row : acc)

partByIterX100 :: [X100Column] -> [(Int, [(Int, Maybe X100Data)])]
partByIterX100 d = pbi d'  
    where
        d' :: [(Int, Int, Maybe X100Data)]
        d' = case d of
                [descr, p, i] -> zip3 (map convert descr) (map convert p) (map Just i)
                [descr, p] -> zip3 (map convert descr) (map convert p) (repeat Nothing)
        pbi :: [(Int, Int, Maybe X100Data)] -> [(Int, [(Int, Maybe X100Data)])]
        pbi vs = [ (the i, zip p it) | (i, p, it) <- vs
                                     , then group by i]
        
partByIter :: Int -> [[SqlValue]] -> [(Int, [(Int, [SqlValue])])]
partByIter iC vs = pbi (zip [1..] vs)
    where
        pbi :: [(Int, [SqlValue])] -> [(Int, [(Int, [SqlValue])])]
        pbi ((p,v):vs) = let i = getIter v
                             (vi, vr) = span (\(p',v') -> i == getIter v') vs
                          in (i, (p, v):vi) : pbi vr
        pbi []         = []
        getIter :: [SqlValue] -> Int
        getIter vals = ((fromSql (vals !! iC))::Int)
        
type ResultInfo = (Int, Maybe (String, Int))

-- | Transform algebraic plan scheme info into resultinfo
schemeToResult :: P.Schema -> [(String, SqlColDesc)] -> ResultInfo
schemeToResult (itN, col) resDescr = let resColumns = flip zip [0..] $ map (\(c, _) -> takeWhile (\a -> a /= '_') c) resDescr
                                         itC = fromJust $ lookup itN resColumns
                                      in (itC, fmap (\(n, _) -> (n, fromJust $ lookup n resColumns)) col)
