{-# LANGUAGE TemplateHaskell #-}

module Optimizer.VL.Rewrite.PruneEmpty(pruneEmpty) where

import Control.Monad
import Control.Applicative

import Optimizer.VL.Properties.Types
import Optimizer.VL.Rewrite.Common
  
import Optimizer.Common.Match
import Optimizer.Common.Traversal

import Database.Algebra.Rewrite
import Database.Algebra.Dag.Common
import Database.Algebra.VL.Data

pruneEmpty :: VLRewrite Bool
pruneEmpty = postOrder inferBottomUp emptyRules

emptyRules :: VLRuleSet BottomUpProps
emptyRules = [ emptyAppendLeftR1
             , emptyAppendLeftR3
             , emptyAppendRightR1
             , emptyAppendRightR2
             ]
             
isEmpty :: AlgNode -> OptMatch VL BottomUpProps Bool
isEmpty q = do
  ps <- liftM emptyProp $ properties q
  case ps of
    VProp b -> return b
    x       -> error $ "PruneEmpty.isEmpty: non-vector input " ++ show x

{- If the left input is empty and the other is not, the resulting value vector
is simply the right input. -}
emptyAppendLeftR1 :: VLRule BottomUpProps
emptyAppendLeftR1 q =
  $(pattern [| q |] "R1 ((q1) Append (q2))"
    [| do
        predicate =<< ((&&) <$> (isEmpty $(v "q1")) <*> (not <$> isEmpty $(v "q2")))

        return $ do
          logRewrite "Empty.Append.Left.R1" q
          replaceRoot q $(v "q2")
          relinkParents q $(v "q2") |])
  
{- If the left input is empty, a propagation vector for the right side
needs to be generated nevertheless. However, since no input comes from
the right side, the propagation vector is simply a NOOP because it
maps pos (posold) to pos (posnew). -}
emptyAppendLeftR3 :: VLRule BottomUpProps
emptyAppendLeftR3 q =
  $(pattern [| q |] "R3 ((q1) Append (q2))"
    [| do
        predicate =<< ((&&) <$> (isEmpty $(v "q1")) <*> (not <$> isEmpty $(v "q2")))
        return $ do
          logRewrite "Empty.Append.Left.R3" q
          replace q $ UnOp (ProjectRename (STPosCol, STPosCol)) $(v "q2") |])
          
emptyAppendRightR1 :: VLRule BottomUpProps
emptyAppendRightR1 q =
  $(pattern [| q |] "R1 ((q1) Append (q2))"
    [| do
        predicate =<< ((&&) <$> (isEmpty $(v "q2")) <*> (not <$> isEmpty $(v "q1")))
        return $ do
          logRewrite "Empty.Append.Right.R1" q
          replaceRoot q $(v "q1")
          relinkParents q $(v "q1") |])

emptyAppendRightR2 :: VLRule BottomUpProps
emptyAppendRightR2 q =
  $(pattern [| q |] "R2 ((q1) Append (q2))"
    [| do
        predicate =<< ((&&) <$> (isEmpty $(v "q2")) <*> (not <$> isEmpty $(v "q1")))
        return $ do
          logRewrite "Empty.Append.Right.R2" q
          replace q $ UnOp (ProjectRename (STPosCol, STPosCol)) $(v "q1") |])
