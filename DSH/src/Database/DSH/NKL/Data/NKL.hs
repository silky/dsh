{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}

module Database.DSH.NKL.Data.NKL 
  ( Expr(..)
  , Typed(..)
  , freeVars
  , Prim1Op(..)
  , Prim2Op(..)
  , Prim1(..)
  , Prim2(..)
  , Column
  , Key
  ) where

import           Text.PrettyPrint.ANSI.Leijen
import           Text.Printf

import           Database.DSH.Common.Data.Op
import           Database.DSH.Common.Data.JoinExpr
import           Database.DSH.Common.Data.Expr
import           Database.DSH.Common.Data.Val(Val())
import           Database.DSH.Common.Data.Type(Type, Typed, typeOf)
  
import qualified Data.Set as S

-- | Nested Kernel Language (NKL) expressions
data Expr  =  Table Type String [Column] [Key]
           |  App Type Expr Expr
           |  AppE1 Type (Prim1 Type) Expr
           |  AppE2 Type (Prim2 Type) Expr Expr
           |  BinOp Type Oper Expr Expr
           |  Lam Type Ident Expr
           |  If Type Expr Expr Expr
           |  Const Type Val
           |  Var Type Ident

instance Typed Expr where
  typeOf (Table t _ _ _) = t
  typeOf (App t _ _)     = t
  typeOf (AppE1 t _ _)   = t
  typeOf (AppE2 t _ _ _) = t
  typeOf (Lam t _ _)     = t
  typeOf (If t _ _ _)    = t
  typeOf (BinOp t _ _ _) = t
  typeOf (Const t _)     = t
  typeOf (Var t _)       = t

instance Show Expr where
  show e = (displayS $ renderPretty 0.9 100 $ pp e) ""

pp :: Expr -> Doc
pp (Table _ n _ _)    = text "table" <+> text n
pp (App _ e1 e2)      = (parenthize e1) <+> (parenthize e2)
pp (AppE1 _ p1 e)     = (text $ show p1) <+> (parenthize e)
pp (AppE2 _ p1 e1 e2) = (text $ show p1) <+> (align $ (parenthize e1) </> (parenthize e2))
pp (BinOp _ o e1 e2)  = (parenthize e1) <+> (text $ show o) <+> (parenthize e2)
pp (Lam _ v e)        = char '\\' <> text v <+> text "->" <+> pp e
pp (If _ c t e)       = text "if" 
                         <+> pp c 
                         <+> text "then" 
                         <+> (parenthize t) 
                         <+> text "else" 
                         <+> (parenthize e)
pp (Const _ v)        = text $ show v
pp (Var _ s)          = text s

parenthize :: Expr -> Doc
parenthize e = 
    case e of
        Var _ _        -> pp e
        Const _ _      -> pp e
        Table _ _ _ _  -> pp e
        _              -> parens $ pp e

deriving instance Eq Expr
deriving instance Ord Expr

freeVars :: Expr -> S.Set String
freeVars (Table _ _ _ _) = S.empty
freeVars (App _ e1 e2) = freeVars e1 `S.union` freeVars e2
freeVars (AppE1 _ _ e1) = freeVars e1
freeVars (AppE2 _ _ e1 e2) = freeVars e1 `S.union` freeVars e2
freeVars (Lam _ x e) = (freeVars e) S.\\ S.singleton x
freeVars (If _ e1 e2 e3) = freeVars e1 `S.union` freeVars e2 `S.union` freeVars e3
freeVars (BinOp _ _ e1 e2) = freeVars e1 `S.union` freeVars e2
freeVars (Const _ _) = S.empty
freeVars (Var _ x) = S.singleton x

data Prim1Op = Length |  Not |  Concat 
             | Sum | Avg | The | Fst | Snd 
             | Head | Minimum | Maximum 
             | IntegerToDouble | Tail 
             | Reverse | And | Or 
             | Init | Last | Nub 
             | Number
             deriving (Eq, Ord)
             
data Prim1 t = Prim1 Prim1Op t deriving (Eq, Ord)

instance Show Prim1Op where
  show Length          = "length"
  show Not             = "not"
  show Concat          = "concat"
  show Sum             = "sum"
  show Avg             = "avg"
  show The             = "the"
  show Fst             = "fst"
  show Snd             = "snd"
  show Head            = "head"
  show Minimum         = "minimum"
  show Maximum         = "maximum"
  show IntegerToDouble = "integerToDouble"
  show Tail            = "tail"
  show Reverse         = "reverse"
  show And             = "and"
  show Or              = "or"
  show Init            = "init"
  show Last            = "last"
  show Nub             = "nub"
  show Number          = "number"
  
instance Show (Prim1 t) where
  show (Prim1 o _) = show o

data Prim2Op = Map 
             | GroupWithKey
             | SortWith 
             | Pair
             | Filter 
             | Append
             | Index 
             | Take
             | Drop 
             | Zip
             | TakeWhile
             | DropWhile
             | CartProduct
             | EquiJoin JoinExpr JoinExpr
             | NestJoin JoinExpr JoinExpr
             | SemiJoin JoinExpr JoinExpr
             | AntiJoin JoinExpr JoinExpr
             deriving (Eq, Ord)
             
data Prim2 t = Prim2 Prim2Op t deriving (Eq, Ord)

instance Show Prim2Op where
  show Map          = "map"
  show GroupWithKey = "groupWithKey"
  show SortWith     = "sortWith"
  show Pair         = "pair"
  show Filter       = "filter"
  show Append       = "append"
  show Index        = "index"
  show Take         = "take"
  show Drop         = "drop"
  show Zip          = "zip"
  show TakeWhile    = "takeWhile"
  show DropWhile    = "dropWhile"
  show CartProduct  = "\xc397"
  show (EquiJoin e1 e2) = printf "\x2a1d (%s | %s)" (show e1) (show e2)
  show (NestJoin e1 e2) = printf "\x25b3 (%s | %s)" (show e1) (show e2)
  show (SemiJoin e1 e2) = printf "\x22c9 (%s | %s)" (show e1) (show e2)
  show (AntiJoin e1 e2) = printf "\x25b7 (%s | %s)" (show e1) (show e2)
  
instance Show (Prim2 t) where
  show (Prim2 o _) = show o