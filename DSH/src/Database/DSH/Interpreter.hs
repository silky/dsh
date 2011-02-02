{-# LANGUAGE TemplateHaskell, ViewPatterns, ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}

module Database.DSH.Interpreter (fromQ) where

import Database.DSH.Data
import Database.DSH.Impossible (impossible)
import Database.DSH.CSV (csvImport)

import Data.Convertible
import Database.HDBC
import GHC.Exts
import Data.List

-- * Convert DB queries into Haskell values
fromQ :: (QA a, IConnection conn) => conn -> Q a -> IO a
fromQ c (Q a) = evaluate c a >>= (return . fromNorm)

evaluate :: IConnection conn
         => conn                -- ^ The HDBC connection
         -> Exp
         -> IO Norm
evaluate c e = case e of
  UnitE t      -> return (UnitN t)
  BoolE b t    -> return (BoolN b t)
  CharE ch t   -> return (CharN ch t)
  IntegerE i t -> return (IntegerN i t)
  DoubleE d t  -> return (DoubleN d t)
  TextE s t    -> return (TextN s t)
  TimeE u t    -> return (TimeN u t)

  VarE _ _ -> $impossible
  LamE _ _ -> $impossible

  AppE f1 e1 _ -> evaluate c (f1 e1)

  TupleE e1 e2 t -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return (TupleN e3 e4 t)

  ListE es t -> do
      es1 <- mapM (evaluate c) es
      return (ListN es1 t)

  AppE3 Cond cond a b _ -> do
      (BoolN c1 _) <- evaluate c cond
      if c1 then evaluate c a else evaluate c b

  AppE2 Cons a as t -> do
    a1 <- evaluate c a
    (ListN as1 _) <- evaluate c as
    return $ ListN (a1 : as1) t

  AppE2 Snoc as a t -> do
    a1 <- evaluate c a
    (ListN as1 _) <- evaluate c as
    return $ ListN (snoc as1 a1) t

  AppE1 Head as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ head as1

  AppE1 Tail as t -> do
    (ListN as1 _) <- evaluate c as
    return $ ListN (tail as1) t

  AppE2 Take i as t -> do
    (IntegerN i1 _) <- evaluate c i
    (ListN as1 _) <- evaluate c as
    return $ ListN (take (fromIntegral i1) as1) t

  AppE2 Drop i as t -> do
    (IntegerN i1 _) <- evaluate c i
    (ListN as1 _) <- evaluate c as
    return $ ListN (drop (fromIntegral i1) as1) t

  AppE2 Map lam as t -> do
    (ListN as1 _) <- evaluate c as
    evaluate c $ ListE (map (evalLam lam) as1) t

  AppE2 Append as bs t -> do
    (ListN as1 _) <- evaluate c as
    (ListN bs1 _) <- evaluate c bs
    return $ ListN (as1 ++ bs1) t

  AppE2 Filter lam as t -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (ListT BoolT))
    return $ ListN (map fst (filter (\(_,(BoolN b BoolT)) -> b) (zip as1 as2))) t

  AppE2 GroupWith lam as t -> do
    (ListN as1 t1) <- evaluate c as
    (ListN as2 _ ) <- evaluate c (ListE (map (evalLam lam) as1) (ListT (typeArrowResult (typeExp lam))))
    return $ ListN (map ((flip ListN) t1 . (map fst)) $ groupWith snd $ zip as1 as2) t

  AppE2 SortWith lam as t -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (ListT (typeArrowResult (typeExp lam))))
    return $ ListN (map fst $ sortWith snd $ zip as1 as2) t

  AppE2 Max e1 e2 IntegerT -> do
     (IntegerN v1 _) <- evaluate c e1
     (IntegerN v2 _) <- evaluate c e2
     return $ IntegerN (max v1 v2) IntegerT

  AppE2 Max e1 e2 DoubleT -> do
     (DoubleN v1 _) <- evaluate c e1
     (DoubleN v2 _) <- evaluate c e2
     return $ DoubleN (max v1 v2) DoubleT

  AppE2 Min e1 e2 IntegerT -> do
     (IntegerN v1 _) <- evaluate c e1
     (IntegerN v2 _) <- evaluate c e2
     return $ IntegerN (min v1 v2) IntegerT

  AppE2 Min e1 e2 DoubleT -> do
     (DoubleN v1 _) <- evaluate c e1
     (DoubleN v2 _) <- evaluate c e2
     return $ DoubleN (min v1 v2) DoubleT

  AppE1 The as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ the as1

  AppE1 Last as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ last as1

  AppE1 Init as t -> do
    (ListN as1 _) <- evaluate c as
    return $ ListN (init as1) t

  AppE1 Null as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ BoolN (null as1) BoolT

  AppE1 Length as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ IntegerN (fromIntegral $ length as1) IntegerT

  AppE2 Index as i _ -> do
    (IntegerN i1 _) <- evaluate c i
    (ListN as1 _) <- evaluate c as
    return $ as1 !! (fromIntegral i1)

  AppE1 Reverse as t -> do
    (ListN as1 _) <- evaluate c as
    return $ ListN (reverse as1) t

  AppE1 And as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ BoolN (and $ map (\(BoolN b BoolT) -> b) as1) BoolT

  AppE1 Or as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ BoolN (or $ map (\(BoolN b BoolT) -> b) as1) BoolT

  AppE2 Any lam as _ -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ BoolN (any id $ map (\(BoolN b BoolT) -> b) as2) BoolT

  AppE2 All lam as _ -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ BoolN (all id $ map (\(BoolN b BoolT) -> b) as2) BoolT

  AppE1 Sum as IntegerT -> do
    (ListN as1 _) <- evaluate c as
    return $ IntegerN (sum $ map (\(IntegerN i IntegerT) -> i) as1) IntegerT

  AppE1 Sum as DoubleT -> do
    (ListN as1 _) <- evaluate c as
    return $ DoubleN (sum $ map (\(DoubleN d DoubleT) -> d) as1) DoubleT

  AppE1 Sum _ _ -> $impossible

  AppE1 Concat as t -> do
    (ListN as1 _) <- evaluate c as
    return $ ListN (concat $ map (\(ListN as2 _) -> as2) as1) t

  AppE1 Maximum as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ maximum as1

  AppE1 Minimum as _ -> do
    (ListN as1 _) <- evaluate c as
    return $ minimum as1

  AppE2 SplitAt i as t -> do
    (IntegerN i1 _) <- evaluate c i
    (ListN as1 t1) <- evaluate c as
    let r = splitAt (fromIntegral i1) as1
    return $ TupleN (ListN (fst r) t1) (ListN (snd r) t1) t

  AppE2 TakeWhile lam as t -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ ListN (map fst $ takeWhile (\(_,BoolN b BoolT) -> b) $ zip as1 as2) t

  AppE2 DropWhile lam as t -> do
    (ListN as1 _) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ ListN (map fst $ dropWhile (\(_,BoolN b BoolT) -> b) $ zip as1 as2) t

  AppE2 Span lam as t -> do
    (ListN as1 t1) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ (\(a,b) -> TupleN a b t)
           $ (\(a,b) -> (ListN (map fst a) t1, ListN (map fst b) t1))
           $ span (\(_,BoolN b BoolT) -> b)
           $ zip as1 as2

  AppE2 Break lam as t -> do
    (ListN as1 t1) <- evaluate c as
    (ListN as2 _) <- evaluate c (ListE (map (evalLam lam) as1) (typeArrowResult (typeExp lam)))
    return $ (\(a,b) -> TupleN a b t)
           $ (\(a,b) -> (ListN (map fst a) t1, ListN (map fst b) t1))
           $ break (\(_,BoolN b BoolT) -> b)
           $ zip as1 as2

  AppE2 Zip as bs t -> do
    (ListN as1 (ListT t1)) <- evaluate c as
    (ListN bs1 (ListT t2)) <- evaluate c bs
    return $ ListN (zipWith (\a b -> TupleN a b (TupleT t1 t2)) as1 bs1) t

  AppE1 Unzip as t -> do
    (ListN as1 (ListT (TupleT t1 t2))) <- evaluate c as
    return $ TupleN (ListN (map (\(TupleN a _ _) -> a) as1) (ListT t1))
                    (ListN (map (\(TupleN _ b _) -> b) as1) (ListT t2))
                    t

  AppE3 ZipWith lam as bs t -> do
    (ListN as1 _) <- evaluate c as
    (ListN bs1 _) <- evaluate c bs
    evaluate c $ ListE (zipWith (\a b -> let lam1 = ((evalLam lam) a) in (evalLam lam1) b) as1 bs1) t

  AppE1 Nub as t -> do
    (ListN as1 _) <- evaluate c as
    return $ ListN (nub as1) t

  AppE1 Fst a _ -> do
    (TupleN a1 _ _) <- evaluate c a
    return a1

  AppE1 Snd a _ -> do
    (TupleN _ a1 _) <- evaluate c a
    return a1

  AppE2 Add e1 e2 IntegerT -> do
    (IntegerN i1 _) <- evaluate c e1
    (IntegerN i2 _) <- evaluate c e2
    return $ IntegerN (i1 + i2) IntegerT
  AppE2 Add e1 e2 DoubleT -> do
    (DoubleN d1 _) <- evaluate c e1
    (DoubleN d2 _) <- evaluate c e2
    return $ DoubleN (d1 + d2) DoubleT
  AppE2 Add _ _ _ -> $impossible

  AppE2 Sub e1 e2 IntegerT -> do
    (IntegerN i1 _) <- evaluate c e1
    (IntegerN i2 _) <- evaluate c e2
    return $ IntegerN (i1 - i2) IntegerT
  AppE2 Sub e1 e2 DoubleT -> do
    (DoubleN d1 _) <- evaluate c e1
    (DoubleN d2 _) <- evaluate c e2
    return $ DoubleN (d1 - d2) DoubleT
  AppE2 Sub _ _ _ -> $impossible

  AppE2 Mul e1 e2 IntegerT -> do
    (IntegerN i1 _) <- evaluate c e1
    (IntegerN i2 _) <- evaluate c e2
    return $ IntegerN (i1 * i2) IntegerT
  AppE2 Mul e1 e2 DoubleT -> do
    (DoubleN d1 _) <- evaluate c e1
    (DoubleN d2 _) <- evaluate c e2
    return $ DoubleN (d1 * d2) DoubleT
  AppE2 Mul _ _ _ -> $impossible
  
  AppE2 Div e1 e2 DoubleT -> do
    (DoubleN d1 _) <- evaluate c e1
    (DoubleN d2 _) <- evaluate c e2
    return $ DoubleN (d1 / d2) DoubleT
  AppE2 Div _ _ _ -> $impossible
  
  AppE1 IntegerToDouble e1 DoubleT -> do
    (IntegerN i1 _) <- evaluate c e1
    return $ DoubleN (fromInteger i1) DoubleT
    
  AppE1 IntegerToDouble _ _ -> $impossible

  AppE2 Equ e1 e2 _ -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return $ BoolN (e3 == e4) BoolT

  AppE2 Lt e1 e2 _ -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return $ BoolN (e3 < e4) BoolT

  AppE2 Lte e1 e2 _ -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return $ BoolN (e3 <= e4) BoolT

  AppE2 Gte e1 e2 _ -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return $ BoolN (e3 >= e4) BoolT

  AppE2 Gt e1 e2 _ -> do
    e3 <- evaluate c e1
    e4 <- evaluate c e2
    return $ BoolN (e3 > e4) BoolT

  AppE1 Not e1 _ -> do
    (BoolN b1 _) <- evaluate c e1
    return $ BoolN (not b1) BoolT

  AppE2 Conj e1 e2 _ -> do
    (BoolN b1 _) <- evaluate c e1
    (BoolN b2 _) <- evaluate c e2
    return $ BoolN (b1 && b2) BoolT

  AppE2 Disj e1 e2 _ -> do
    (BoolN b1 _) <- evaluate c e1
    (BoolN b2 _) <- evaluate c e2
    return $ BoolN (b1 || b2) BoolT

  TableE (TableDB (escape -> tName) _) (ListT tType) -> do
      tDesc <- describeTable c tName
      let columnNames = concat $ intersperse " , " $ map (\s -> "\"" ++ s ++ "\"") $ sort $ map fst tDesc
      let query = "SELECT " ++ columnNames ++ " FROM " ++ "\"" ++ tName ++ "\""
      print query
      fmap (sqlToNormWithType tName tType) (quickQuery c query [])
  TableE (TableCSV filename) t -> csvImport filename t
  TableE _ _ -> $impossible


snoc :: [a] -> a -> [a]
snoc [] a = [a]
snoc (b : bs) a = b : snoc bs a

escape :: String -> String
escape []                  = []
escape (c : cs) | c == '"' = '\\' : '"' : escape cs
escape (c : cs)            =          c : escape cs

evalLam :: Exp -> (Norm -> Exp)
evalLam (LamE f _) n = f (convert n)
evalLam _ _ = $impossible


-- | Read SQL values into 'Norm' values
sqlToNormWithType :: String             -- ^ Table name, used to generate more
                                        -- informative error messages
                  -> Type
                  -> [[SqlValue]]
                  -> Norm
sqlToNormWithType tName ty = (flip ListN) (ListT ty) . map (sqlValueToNorm ty)

  where
    sqlValueToNorm :: Type -> [SqlValue] -> Norm

    -- On a single value, just compare the 'Type' and convert the 'SqlValue' to
    -- a Norm value on match
    sqlValueToNorm t [s] = if t `typeMatch` s
                      then convert s
                      else typeError t [s]

    -- On more than one value we need a 'TupleT' type of the exact same length
    sqlValueToNorm t s | length (unfoldType t) == length s =
            let f t' s' = if t' `typeMatch` s'
                             then convert s'
                             else typeError t s
            in foldr1 (\a b -> TupleN a b (TupleT (typeNorm a) (typeNorm b)))
                      (zipWith f (unfoldType t) s)

    -- Everything else will raise an error
    sqlValueToNorm t s = typeError t s

    typeError :: Type -> [SqlValue] -> a
    typeError t s = error $
        "ferry: Type mismatch on table \"" ++ tName ++ "\":"
        ++ "\n\tExpected table type: " ++ show t
        ++ "\n\tTable entry: " ++ show s


-- | Check if a 'SqlValue' matches a 'Type'
typeMatch :: Type -> SqlValue -> Bool
typeMatch t s =
    case (t,s) of
         (UnitT         , SqlNull)          -> True
         (IntegerT      , SqlInteger _)     -> True
         (DoubleT       , SqlDouble _)      -> True
         (BoolT         , SqlBool _)        -> True
         (CharT         , SqlChar _)        -> True
         (TextT         , SqlString _)      -> True
         (TextT         , SqlByteString _)  -> True
         (TimeT         , SqlLocalTime _)   -> True
         (TimeT         , SqlLocalDate _)   -> True
         _                                  -> False