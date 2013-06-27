{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Optimizer.VL.Rewrite.Specialized where

import           Control.Applicative
import           Control.Monad

import           Database.Algebra.Dag.Common
import           Database.Algebra.VL.Data
import           Database.DSH.Optimizer.VL.Properties.AbstractDomains

import           Database.DSH.Optimizer.Common.Rewrite
import           Database.DSH.Optimizer.VL.Properties.Types
import           Database.DSH.Optimizer.VL.Properties.VectorType
import           Database.DSH.Optimizer.VL.Rewrite.Common

introduceSpecializedOperators :: VLRewrite Bool
introduceSpecializedOperators = iteratively $ sequenceRewrites [ normalize
                                                               , applyToAll inferBottomUp specializedRules ]

normalize :: VLRewrite Bool
normalize = iteratively $ sequenceRewrites [ applyToAll noProps normalizeRules
                                           , applyToAll inferBottomUp normalizePropRules ]

normalizeRules :: VLRuleSet ()
normalizeRules = [ mergeStackedDistLift
                 , pullProjectLThroughDistLift
                 ]

normalizePropRules :: VLRuleSet BottomUpProps
normalizePropRules = [ redundantDistLift
                     , pruneFilteringDistLift
                     , pullProjectLThroughCartProductRight
                     , pullProjectLThroughCartProductLeft
                     ]

specializedRules :: VLRuleSet BottomUpProps
specializedRules = [ cartProduct ]

-- We often see a pattern around cartesian products where the same vector is
-- lifted two times in a row with the same descriptor vector. The second lift
-- is completely redundant.
mergeStackedDistLift :: VLRule ()
mergeStackedDistLift q =
  $(pattern 'q "R1 ((valVec1) DistLift (first=R1 ((valVec2) DistLift (_))))"
    [| do
        predicate $ $(v "valVec1") == $(v "valVec2")
        return $ do
          logRewrite "Specialized.MergeStackedDistLift" q
          replace q $(v "first") |])

{- Normalize the cartesian product pattern by pulling horizontal
modifications (projections, general expressions) as high as possible
-}

-- If a DistLift lifts the output of a projection, apply the projection after
-- the DistLift. This is necessary to keep all payload data as long as necessary
-- and thereby normalize cartesian product patterns.
pullProjectLThroughDistLift :: VLRule ()
pullProjectLThroughDistLift q =
  $(pattern 'q "R1 ((ProjectL p (qv)) DistLift (qd))"
    [| do
        return $ do
          logRewrite "Specialized.PullProjectLThroughDistLift" q
          liftNode <- insert $ BinOp DistLift $(v "qv") $(v "qd")
          r1Node   <- insert $ UnOp R1 liftNode
          void $ replaceWithNew q $ UnOp (ProjectL $(v "p")) r1Node |])

pullProjectLThroughCartProductLeft :: VLRule BottomUpProps
pullProjectLThroughCartProductLeft q =
  $(pattern 'q "R1 ((ProjectL p (q1)) CartProduct (q2))"
    [| do
        propsLeft <- properties $(v "q1")
        propsRight <- properties $(v "q2")
        let leftWidth = case vectorTypeProp propsLeft of
                          VProp (ValueVector w) -> w
                          _                     -> error "not a value vector"
            rightWidth = case vectorTypeProp propsRight of
                           VProp (ValueVector w) -> w
                           _                     -> error "not a value vector"

        return $ do
          logRewrite "Specialized.PullProjectLThroughCartProduct.Left" q
          prodNode <- insert $ BinOp CartProduct $(v "q1") $(v "q2")
          r1Node <- insert $ UnOp R1 prodNode
          let p' = $(v "p") ++ (map (+ leftWidth) [1 .. rightWidth])
          void $ replaceWithNew q $ UnOp (ProjectL p') r1Node |])

pullProjectLThroughCartProductRight :: VLRule BottomUpProps
pullProjectLThroughCartProductRight q =
  $(pattern 'q "R1 ((q1) CartProduct (ProjectL p (q2)))"
    [| do
        propsLeft <- properties $(v "q1")
        let leftWidth = case vectorTypeProp propsLeft of
                          VProp (ValueVector w) -> w
                          _                     -> error "not a value vector"

        return $ do
          logRewrite "Specialized.PullProjectLThroughCartProduct.Right" q
          prodNode <- insert $ BinOp CartProduct $(v "q1") $(v "q2")
          r1Node <- insert $ UnOp R1 prodNode
          let p' = [1 .. leftWidth] ++ (map (+ leftWidth) $(v "p"))
          void $ replaceWithNew q $ UnOp (ProjectL p') r1Node |])

-- Eliminate a common pattern where the output of a cartesian product is turned into a
-- descriptor vector and used to lift one of the product inputs. This is redundant because
-- the CartProduct operator already provides the data originating from the lift.

-- FIXME this is propably just a special case of rule pruneFilteringDistLift
redundantDistLift:: VLRule BottomUpProps
redundantDistLift q =
  $(pattern 'q "R1 ((qv) DistLift (qp=R1 ((qv1) CartProduct (qv2))))"
    [| do
        predicate $ $(v "qv") == $(v "qv1") || $(v "qv") == $(v "qv2")

        vt1 <- vectorTypeProp <$> properties $(v "qv1")
        let w1 = case vt1 of
                   VProp (ValueVector w) -> w
                   _                     -> error "redundantDistLift: no ValueVector on the left side"

        vt2 <- vectorTypeProp <$> properties $(v "qv2")
        let w2 = case vt2 of
                   VProp (ValueVector w) -> w
                   _                     -> error "redundantDistLift: no ValueVector on the right side"

        return $ do
          let (p, msg) = if $(v "qv") == $(v "qv1")
                         then ([1 .. w1], "Specialized.RedundantDistLift.Left")
                         else ([(w1 + 1) .. w2], "Specialized.RedundantDistLift.Right")
          logRewrite msg q
          void $ replaceWithNew q $ UnOp (ProjectL p) $(v "qp") |])

-- FIXME This matches only a special case: If DistLift is to be
-- replaced by the right input, the original descriptor before it is
-- overwritten with the positions to align with the left side must be
-- kept/restored.
pruneFilteringDistLift :: VLRule BottomUpProps
pruneFilteringDistLift q =
  $(pattern 'q "R1 ((q1) DistLift (qp=ProjectAdmin _ (_)))"
    [| do
        props1 <- properties $(v "q1")
        propsp <- properties $(v "qp")

        {- The following properties need to hold:
           1. q2.descr must be a subdomain of the domain of q1.pos
           2. q2 payload must be untainted with respect to the node
              from where the q1.pos domain originates
        -}

        let q1Pos = case indexSpaceProp props1 of
              VProp (DBVSpace _ (P pis)) -> pis
              _                          -> error "foo"

            qpDescr = case indexSpaceProp propsp of
              VProp (DBVSpace (D dis) _) -> dis
              _                          -> error "foo"

            untaintedNodes = case untaintedProp propsp of
              VProp (Just nodes) -> nodes
              _                  -> []

        let q1OriginNode = case domainNode q1Pos of
              Just n  -> n
              Nothing -> error "foo"

        predicate $ subDomain qpDescr q1Pos

        predicate $ q1OriginNode `elem` untaintedNodes

        return $ do
          logRewrite "Specialized.PruneFilteringDistLift" q
          replace q $(v "qp") |])

{-

Introduce a specialized CartProd operator:

Rewrite the following pattern into a CartProd operator:

        R1
        |
        DistLift
       /|
      / ToDescr
     /  |
    q2  R1
        |
        DistDesc
       /\
      /  \
     q1   \
           \
           ToDescr
            |
            q2

This pattern first distributes q1 over q2, producing a vector with the payload data of q1
and cardinality q1 x q2. Next, q2 is distributed (with lifted semantics) over the resulting
descriptor, producing a vector with the payload data of q2 and the same cardinality.

This pattern can be rewritten into a specialized CartProd operator which keeps the data of
inputs.

     ProjectL    ProjectL
          \        /
           \      /
            \    /
           CartProd
             /\
            /  \
           q1   q2

-}
cartProduct :: VLRule BottomUpProps
cartProduct q =
  $(pattern 'q "R1 (qLift=(liftInput) DistLift (right=R1 (qDesc=(rightInput) DistDesc (leftInput))))"
    [| do
        predicate $ $(v "liftInput") == $(v "leftInput")

        s1 <- vectorTypeProp <$> properties $(v "leftInput")
        s2 <- vectorTypeProp <$> properties $(v "rightInput")

        let (w1, w2) = (vectorWidth s1, vectorWidth s2)

        return $ do
          logRewrite "Specialized.CartProduct" q

          -- Auxilliary function to find all R2 operators which reference a given node

          -- The CartProduct operator itself
          prodNode <- insert $ BinOp CartProduct $(v "leftInput") $(v "rightInput")

          prodR1 <- insert $ UnOp R1 prodNode

          -- relink operators which reference the product result with the payload from
          -- left and right input to the respective projections.
          void $ replaceWithNew q $ UnOp (ProjectL [1 .. w1]) prodR1
          void $ replaceWithNew $(v "right") $ UnOp (ProjectL [(w1 + 1) .. (w1 + w2)]) prodR1

          -- check if the R2 outputs (propagation vectors) of DistDesc and DistLift are
          -- referenced and relink them to the corresponding R2 and R3 outputs of CartProduct
          -- if necessary.

          let r2Parents n = do
                let isR2 (UnOp R2 _) = True
                    isR2 _           = False
                ps <- parents n
                ops <- mapM operator ps
                return $ map fst $ filter (\(_, o) -> isR2 o) $ zip ps ops

          liftR2s <- r2Parents $(v "qLift")
          case liftR2s of
            [liftR2] -> void $ replaceWithNew liftR2 $ UnOp R2 prodNode
            _        -> return ()

          descR2s <- r2Parents $(v "qDesc")
          case descR2s of
            [descR2] -> void $ replaceWithNew descR2 $ UnOp R3 prodNode
            _        -> return () |])
  