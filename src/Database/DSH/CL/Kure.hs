{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE InstanceSigs          #-}

-- | Infrastructure for KURE-based rewrites on CL expressions
   
module Database.DSH.CL.Kure
    ( -- * Re-export relevant KURE modules
      module Language.KURE
    , module Language.KURE.Lens

      -- * The KURE monad
    , RewriteM, RewriteStateM, TransformC, RewriteC, LensC, freshName, freshNameT
    
      -- * Setters and getters for the translation state
    , get, put, modify
    
      -- * Changing between stateful and non-stateful transforms
    , statefulT, liftstateT

      -- * The KURE context
    , CompCtx(..), CrumbC(..), PathC, initialCtx, freeIn, boundIn
    , inScopeNames, bindQual, bindVar, withLocalPathT

      -- * Congruence combinators
    , tableT, appT, appe1T, appe2T, binopT, lamT, ifT, litT, varT, compT
    , tableR, appR, appe1R, appe2R, binopR, lamR, ifR, litR, varR, compR
    , unopR, unopT
    , bindQualT, guardQualT, bindQualR, guardQualR
    , qualsT, qualsR, qualsemptyT, qualsemptyR
    
      -- * The sum type
    , CL(..)
    ) where
    
       
import           Control.Monad
import           Data.Monoid
import qualified Data.Map as M
import qualified Data.Foldable as F
import           Text.PrettyPrint.ANSI.Leijen(text)

import           Language.KURE
import           Language.KURE.Lens
       
import           Database.DSH.Common.Pretty
import qualified Database.DSH.Common.Lang as L
import           Database.DSH.Common.RewriteM
import           Database.DSH.CL.Lang
                 
--------------------------------------------------------------------------------
-- Convenience type aliases

type TransformC a b = Transform CompCtx (RewriteM Int) a b
type RewriteC a     = TransformC a a
type LensC a b      = Lens CompCtx (RewriteM Int) a b

--------------------------------------------------------------------------------

data CrumbC = AppFun
            | AppArg
            | AppE1Arg
            | AppE2Arg1
            | AppE2Arg2
            | BinOpArg1
            | BinOpArg2
            | UnOpArg
            | LamBody
            | IfCond
            | IfThen
            | IfElse
            | CompHead
            | CompQuals
            | BindQualExpr
            | GuardQualExpr
            | QualsHead
            | QualsTail
            | QualsSingleton
            | NLConsTail
            deriving (Eq, Show)

instance Pretty CrumbC where
    pretty c = text $ show c

type AbsPathC = AbsolutePath CrumbC

type PathC = Path CrumbC

-- | The context for KURE-based CL rewrites
data CompCtx = CompCtx { cl_bindings :: M.Map L.Ident Type 
                       , cl_path     :: AbsPathC
                       }
                       
instance ExtendPath CompCtx CrumbC where
    c@@n = c { cl_path = cl_path c @@ n }
    
instance ReadPath CompCtx CrumbC where
    absPath c = cl_path c

initialCtx :: CompCtx
initialCtx = CompCtx { cl_bindings = M.empty, cl_path = mempty }

-- | Record a variable binding in the context
bindVar :: L.Ident -> Type -> CompCtx -> CompCtx
bindVar n ty ctx = ctx { cl_bindings = M.insert n ty (cl_bindings ctx) }

-- | If the qualifier represents a generator, bind the variable in the context.
bindQual :: CompCtx -> Qual -> CompCtx
bindQual ctx (BindQ n e) = bindVar n (elemT $ typeOf e) ctx
bindQual ctx _           = ctx
         
inScopeNames :: CompCtx -> [L.Ident]
inScopeNames = M.keys . cl_bindings

boundIn :: L.Ident -> CompCtx -> Bool
boundIn n ctx = n `M.member` (cl_bindings ctx)

freeIn :: L.Ident -> CompCtx -> Bool
freeIn n ctx = n `M.notMember` (cl_bindings ctx)

-- | Generate a fresh name that is not bound in the current context.
freshNameT :: [L.Ident] -> TransformC a L.Ident
freshNameT avoidNames = do
    ctx <- contextT
    constT $ freshName (avoidNames ++ inScopeNames ctx)

-- | Perform a transform with an empty path, i.e. a path starting from
-- the current node.
withLocalPathT :: Monad m => Transform CompCtx m a b -> Transform CompCtx m a b
withLocalPathT t = transform $ \c a -> applyT t (c { cl_path = SnocPath [] }) a

--------------------------------------------------------------------------------
-- Support for stateful transforms

-- | Run a stateful transform with an initial state and turn it into a regular
-- (non-stateful) transform
statefulT :: s -> Transform CompCtx (RewriteStateM s) a b -> TransformC a (s, b)
statefulT s t = resultT (stateful s) t

-- | Turn a regular rewrite into a stateful rewrite
liftstateT :: Transform CompCtx (RewriteM Int) a b -> Transform CompCtx (RewriteStateM s) a b
liftstateT t = resultT liftstate t


--------------------------------------------------------------------------------
-- Congruence combinators for CL expressions

tableT :: Monad m => (Type -> String -> [L.Column] -> L.TableHints -> b)
                  -> Transform CompCtx m Expr b
tableT f = contextfreeT $ \expr -> case expr of
                      Table ty n cs hs -> return $ f ty n cs hs
                      _                -> fail "not a table node"
{-# INLINE tableT #-}                      
                      
tableR :: Monad m => Rewrite CompCtx m Expr
tableR = tableT Table
{-# INLINE tableR #-}
                                       
appT :: Monad m => Transform CompCtx m Expr a1
                -> Transform CompCtx m Expr a2
                -> (Type -> a1 -> a2 -> b)
                -> Transform CompCtx m Expr b
appT t1 t2 f = transform $ \c expr -> case expr of
                      App ty e1 e2 -> f ty <$> applyT t1 (c@@AppFun) e1 <*> applyT t2 (c@@AppArg) e2
                      _            -> fail "not an application node"
{-# INLINE appT #-}                      

appR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
appR t1 t2 = appT t1 t2 App
{-# INLINE appR #-}                      
                      
appe1T :: Monad m => Transform CompCtx m Expr a
                  -> (Type -> Prim1 -> a -> b)
                  -> Transform CompCtx m Expr b
appe1T t f = transform $ \c expr -> case expr of
                      AppE1 ty p e -> f ty p <$> applyT t (c@@AppE1Arg) e                  
                      _            -> fail "not a unary primitive application"
{-# INLINE appe1T #-}                      
                      
appe1R :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
appe1R t = appe1T t AppE1
{-# INLINE appe1R #-}                      
                      
appe2T :: Monad m => Transform CompCtx m Expr a1
                  -> Transform CompCtx m Expr a2
                  -> (Type -> Prim2 -> a1 -> a2 -> b)
                  -> Transform CompCtx m Expr b
appe2T t1 t2 f = transform $ \c expr -> case expr of
                     AppE2 ty p e1 e2 -> f ty p <$> applyT t1 (c@@AppE2Arg1) e1 
                                                <*> applyT t2 (c@@AppE2Arg2) e2
                     _                -> fail "not a binary primitive application"
{-# INLINE appe2T #-}                      

appe2R :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
appe2R t1 t2 = appe2T t1 t2 AppE2
{-# INLINE appe2R #-}                      
                     
binopT :: Monad m => Transform CompCtx m Expr a1
                  -> Transform CompCtx m Expr a2
                  -> (Type -> L.ScalarBinOp -> a1 -> a2 -> b)
                  -> Transform CompCtx m Expr b
binopT t1 t2 f = transform $ \c expr -> case expr of
                     BinOp ty op e1 e2 -> f ty op <$> applyT t1 (c@@BinOpArg1) e1 
                                                  <*> applyT t2 (c@@BinOpArg2) e2
                     _                 -> fail "not a binary operator application"
{-# INLINE binopT #-}                      

binopR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
binopR t1 t2 = binopT t1 t2 BinOp
{-# INLINE binopR #-}                      

unopT :: Monad m => Transform CompCtx m Expr a
                 -> (Type -> L.ScalarUnOp -> a -> b)
                 -> Transform CompCtx m Expr b
unopT t f = transform $ \ctx expr -> case expr of
                     UnOp ty op e -> f ty op <$> applyT t (ctx@@UnOpArg) e
                     _            -> fail "not an unary operator application"
{-# INLINE unopT #-}

unopR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
unopR t = unopT t UnOp
{-# INLINE unopR #-}
                     
lamT :: Monad m => Transform CompCtx m Expr a
                -> (Type -> L.Ident -> a -> b)
                -> Transform CompCtx m Expr b
lamT t f = transform $ \c expr -> case expr of
                     Lam ty n e -> f ty n <$> applyT t (bindVar n (domainT ty) c@@LamBody) e
                     _          -> fail "not a lambda"
{-# INLINE lamT #-}                      
                     
lamR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Expr
lamR t = lamT t Lam
{-# INLINE lamR #-}                      
                     
ifT :: Monad m => Transform CompCtx m Expr a1
               -> Transform CompCtx m Expr a2
               -> Transform CompCtx m Expr a3
               -> (Type -> a1 -> a2 -> a3 -> b)
               -> Transform CompCtx m Expr b
ifT t1 t2 t3 f = transform $ \c expr -> case expr of
                    If ty e1 e2 e3 -> f ty <$> applyT t1 (c@@IfCond) e1               
                                           <*> applyT t2 (c@@IfThen) e2
                                           <*> applyT t3 (c@@IfElse) e3
                    _              -> fail "not an if expression"
{-# INLINE ifT #-}                      
                    
ifR :: Monad m => Rewrite CompCtx m Expr
               -> Rewrite CompCtx m Expr
               -> Rewrite CompCtx m Expr
               -> Rewrite CompCtx m Expr
ifR t1 t2 t3 = ifT t1 t2 t3 If               
{-# INLINE ifR #-}                      
                    
litT :: Monad m => (Type -> L.Val -> b) -> Transform CompCtx m Expr b
litT f = contextfreeT $ \expr -> case expr of
                    Lit ty v -> return $ f ty v
                    _          -> fail "not a constant"
{-# INLINE litT #-}                      
                    
litR :: Monad m => Rewrite CompCtx m Expr
litR = litT Lit
{-# INLINE litR #-}                      
                    
varT :: Monad m => (Type -> L.Ident -> b) -> Transform CompCtx m Expr b
varT f = contextfreeT $ \expr -> case expr of
                    Var ty n -> return $ f ty n
                    _        -> fail "not a variable"
{-# INLINE varT #-}                      
                    
varR :: Monad m => Rewrite CompCtx m Expr
varR = varT Var
{-# INLINE varR #-}                      

compT :: Monad m => Transform CompCtx m Expr a1
                 -> Transform CompCtx m (NL Qual) a2
                 -> (Type -> a1 -> a2 -> b)
                 -> Transform CompCtx m Expr b
compT t1 t2 f = transform $ \ctx expr -> case expr of
                    Comp ty e qs -> f ty <$> applyT t1 (F.foldl' bindQual (ctx@@CompHead) qs) e 
                                         <*> applyT t2 (ctx@@CompQuals) qs
                    _            -> fail "not a comprehension"
{-# INLINE compT #-}                      
                    
compR :: Monad m => Rewrite CompCtx m Expr
                 -> Rewrite CompCtx m (NL Qual)
                 -> Rewrite CompCtx m Expr
compR t1 t2 = compT t1 t2 Comp                 
{-# INLINE compR #-}                      

--------------------------------------------------------------------------------
-- Congruence combinators for qualifiers

bindQualT :: Monad m => Transform CompCtx m Expr a 
                     -> (L.Ident -> a -> b) 
                     -> Transform CompCtx m Qual b
bindQualT t f = transform $ \ctx expr -> case expr of
                BindQ n e -> f n <$> applyT t (ctx@@BindQualExpr) e
                _         -> fail "not a generator"
{-# INLINE bindQualT #-}                      
                
bindQualR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Qual
bindQualR t = bindQualT t BindQ
{-# INLINE bindQualR #-}                      

guardQualT :: Monad m => Transform CompCtx m Expr a 
                      -> (a -> b) 
                      -> Transform CompCtx m Qual b
guardQualT t f = transform $ \ctx expr -> case expr of
                GuardQ e -> f <$> applyT t (ctx@@GuardQualExpr) e
                _        -> fail "not a guard"
{-# INLINE guardQualT #-}                      
                
guardQualR :: Monad m => Rewrite CompCtx m Expr -> Rewrite CompCtx m Qual
guardQualR t = guardQualT t GuardQ
{-# INLINE guardQualR #-}                      

--------------------------------------------------------------------------------
-- Congruence combinator for a qualifier list

qualsT :: Monad m => Transform CompCtx m Qual a1
                  -> Transform CompCtx m (NL Qual) a2
                  -> (a1 -> a2 -> b) 
                  -> Transform CompCtx m (NL Qual) b
qualsT t1 t2 f = transform $ \ctx quals -> case quals of
                   q :* qs -> f <$> applyT t1 (ctx@@QualsHead) q 
                                <*> applyT t2 (bindQual (ctx@@QualsTail) q) qs
                   S _     -> fail "not a nonempty cons"
{-# INLINE qualsT #-}                      
                   
qualsR :: Monad m => Rewrite CompCtx m Qual
                  -> Rewrite CompCtx m (NL Qual)
                  -> Rewrite CompCtx m (NL Qual)
qualsR t1 t2 = qualsT t1 t2 (:*)                  
{-# INLINE qualsR #-}                      

                   
qualsemptyT :: Monad m => Transform CompCtx m Qual a
                       -> (a -> b)
                       -> Transform CompCtx m (NL Qual) b
qualsemptyT t f = transform $ \ctx quals -> case quals of
                      S q -> f <$> applyT t (ctx@@QualsSingleton) q
                      _   -> fail "not a nonempty singleton"
{-# INLINE qualsemptyT #-}                      
                      
qualsemptyR :: Monad m => Rewrite CompCtx m Qual
                       -> Rewrite CompCtx m (NL Qual)
qualsemptyR t = qualsemptyT t S                       
{-# INLINE qualsemptyR #-}                      

--------------------------------------------------------------------------------
       
-- | The sum type of *nodes* considered for KURE traversals
data CL = ExprCL Expr
        | QualCL Qual
        | QualsCL (NL Qual)
        
instance Pretty CL where
    pretty (ExprCL e)   = pretty e
    pretty (QualCL q)   = pretty q
    pretty (QualsCL qs) = pretty qs
        
instance Injection Expr CL where
    inject                = ExprCL
    
    project (ExprCL expr) = Just expr
    project _             = Nothing

instance Injection Qual CL where
    inject             = QualCL
    
    project (QualCL q) = Just q
    project _          = Nothing
    
instance Injection (NL Qual) CL where
    inject               = QualsCL
    
    project (QualsCL qs) = Just qs
    project _            = Nothing

    
-- FIXME putting an INLINE pragma on allR would propably lead to good
-- things. However, with 7.6.3 it triggers a GHC panic.
instance Walker CompCtx CL where
    allR :: forall m. MonadCatch m => Rewrite CompCtx m CL -> Rewrite CompCtx m CL
    allR r = 
        rewrite $ \c cl -> case cl of
            ExprCL expr -> inject <$> applyT allRexpr c expr
            QualCL q    -> inject <$> applyT allRqual c q
            QualsCL qs  -> inject <$> applyT allRquals c qs
    
      where
        allRquals = readerT $ \qs -> case qs of
            S{}    -> qualsemptyR (extractR r)
            (:*){} -> qualsR (extractR r) (extractR r)
        {-# INLINE allRquals #-}

        allRqual = readerT $ \q -> case q of
            GuardQ{} -> guardQualR (extractR r)
            BindQ{}  -> bindQualR (extractR r)
        {-# INLINE allRqual #-}

        allRexpr = readerT $ \e -> case e of
            Table{} -> idR
            App{}   -> appR (extractR r) (extractR r)
            AppE1{} -> appe1R (extractR r)
            AppE2{} -> appe2R (extractR r) (extractR r)
            BinOp{} -> binopR (extractR r) (extractR r)
            UnOp{}  -> unopR (extractR r)
            Lam{}   -> lamR (extractR r)
            If{}    -> ifR (extractR r) (extractR r) (extractR r)
            Lit{}   -> idR
            Var{}   -> idR
            Comp{}  -> compR (extractR r) (extractR r)
        {-# INLINE allRexpr #-}
            
--------------------------------------------------------------------------------
-- A Walker instance for qualifier lists so that we can use the
-- traversal infrastructure on lists.
   
consT :: Monad m => Transform CompCtx m (NL Qual) b
                 -> (Qual -> b -> c)
                 -> Transform CompCtx m (NL Qual) c
consT t f = transform $ \ctx nl -> case nl of
                a :* as -> f a <$> applyT t (bindQual (ctx@@NLConsTail) a) as
                S _     -> fail "not a nonempty cons"
{-# INLINE consT #-}                      
                    
consR :: Monad m => Rewrite CompCtx m (NL Qual) 
                 -> Rewrite CompCtx m (NL Qual)
consR t = consT t (:*)                 
{-# INLINE consR #-}                      

singletonT :: Monad m => (Qual -> c)
                      -> Transform CompCtx m (NL Qual) c
singletonT f = contextfreeT $ \nl -> case nl of
                   S a    -> return $ f a
                   _ :* _ -> fail "not a nonempty singleton"
{-# INLINE singletonT #-}                      
               
singletonR :: Monad m => Rewrite CompCtx m (NL Qual)
singletonR = singletonT S                      
{-# INLINE singletonR #-}                      
                   
instance Walker CompCtx (NL Qual) where
    allR r = consR r <+ singletonR
    
--------------------------------------------------------------------------------
-- I find it annoying that Applicative is not a superclass of Monad.

(<$>) :: Monad m => (a -> b) -> m a -> m b
(<$>) = liftM
{-# INLINE (<$>) #-}

(<*>) :: Monad m => m (a -> b) -> m a -> m b
(<*>) = ap
{-# INLINE (<*>) #-}
