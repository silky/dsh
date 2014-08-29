{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving    #-}

module Database.DSH.NKL.Lang
  ( Expr(..)
  , Typed(..)
  , Prim1Op(..)
  , Prim2Op(..)
  , Prim1(..)
  , Prim2(..)
  ) where

import           Text.PrettyPrint.ANSI.Leijen
import           Text.Printf

import qualified Database.DSH.Common.Lang     as L
import           Database.DSH.Common.Pretty
import           Database.DSH.Common.Type     (Type, Typed, typeOf)

-- | Nested Kernel Language (NKL) expressions
data Expr  = Table Type String [L.Column] L.TableHints
           | AppE1 Type (Prim1 Type) Expr
           | AppE2 Type (Prim2 Type) Expr Expr
           | BinOp Type L.ScalarBinOp Expr Expr
           | UnOp Type L.ScalarUnOp Expr
           | If Type Expr Expr Expr
           | Const Type L.Val
           | Var Type L.Ident
           | Comp Type Expr L.Ident Expr
           deriving (Show)

instance Typed Expr where
  typeOf (Table t _ _ _) = t
  typeOf (AppE1 t _ _)   = t
  typeOf (AppE2 t _ _ _) = t
  typeOf (If t _ _ _)    = t
  typeOf (BinOp t _ _ _) = t
  typeOf (UnOp t _ _)    = t
  typeOf (Const t _)     = t
  typeOf (Var t _)       = t
  typeOf (Comp t _ _ _)  = t

instance Pretty Expr where
    pretty (Table _ n _ _)    = text "table" <+> text n
    pretty (AppE1 _ p1 e)     = (text $ show p1) <+> (parenthize e)
    pretty (AppE2 _ p1 e1 e2) = (text $ show p1) <+> (align $ (parenthize e1) </> (parenthize e2))
    pretty (BinOp _ o e1 e2)  = (parenthize e1) <+> (pretty o) <+> (parenthize e2)
    pretty (UnOp _ o e)       = text (show o) <> parens (pretty e)
    pretty (If _ c t e)       = text "if"
                             <+> pretty c
                             <+> text "then"
                             <+> (parenthize t)
                             <+> text "else"
                             <+> (parenthize e)
    pretty (Const _ v)        = text $ show v
    pretty (Var _ s)          = text s
    pretty (Comp _ e x xs)    = brackets $ pretty e <+> char '|' <+> text x <+> text "<-" <+> pretty xs

parenthize :: Expr -> Doc
parenthize e =
    case e of
        Var _ _        -> pretty e
        Const _ _      -> pretty e
        Table _ _ _ _  -> pretty e
        Comp _ _ _ _   -> pretty e
        _              -> parens $ pretty e

deriving instance Eq Expr
deriving instance Ord Expr

data Prim1Op = Length 
             | Concat
             | Sum 
             | Avg 
             | The 
             | Fst 
             | Snd
             | Head 
             | Tail
             | Minimum 
             | Maximum
             | Reverse 
             | And 
             | Or
             | Init 
             | Last 
             | Nub
             | Number
             | Reshape Integer
             | Transpose
             deriving (Eq, Ord)

data Prim1 t = Prim1 Prim1Op t deriving (Eq, Ord)

instance Show Prim1Op where
  show Length          = "length"
  show Concat          = "concat"
  show Sum             = "sum"
  show Avg             = "avg"
  show The             = "the"
  show Fst             = "fst"
  show Snd             = "snd"
  show Head            = "head"
  show Minimum         = "minimum"
  show Maximum         = "maximum"
  show Tail            = "tail"
  show Reverse         = "reverse"
  show And             = "and"
  show Or              = "or"
  show Init            = "init"
  show Last            = "last"
  show Nub             = "nub"
  show Number          = "number"
  show Transpose       = "transpose"
  show (Reshape n)     = printf "reshape(%d)" n

instance Show (Prim1 t) where
  show (Prim1 o _) = show o

data Prim2Op = Group
             | Sort
             | Restrict
             | Pair
             | Append
             | Index
             | Zip
             | Cons
             | CartProduct
             | NestProduct
             | ThetaJoin (L.JoinPredicate L.JoinExpr)
             | NestJoin (L.JoinPredicate L.JoinExpr)
             | SemiJoin (L.JoinPredicate L.JoinExpr)
             | AntiJoin (L.JoinPredicate L.JoinExpr)
             deriving (Eq, Ord)

data Prim2 t = Prim2 Prim2Op t deriving (Eq, Ord)

instance Show Prim2Op where
  show Group        = "group"
  show Sort         = "sort"
  show Restrict     = "restrict"
  show Pair         = "pair"
  show Append       = "append"
  show Index        = "index"
  show Zip          = "zip"
  show Cons         = "cons"
  show CartProduct  = "⨯"
  show NestProduct  = "▽"
  show (ThetaJoin p) = printf "⨝_%s" (pp p)
  show (NestJoin p)  = printf "△_%s" (pp p)
  show (SemiJoin p)  = printf "⋉_%s" (pp p)
  show (AntiJoin p)  = printf "▷_%s" (pp p)

instance Show (Prim2 t) where
  show (Prim2 o _) = show o
