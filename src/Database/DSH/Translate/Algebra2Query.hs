{-# LANGUAGE TemplateHaskell #-}

module Database.DSH.Translate.Algebra2Query
    ( generateX100Queries
    , generateSqlQueries
    ) where

import           Database.DSH.Impossible

import           Database.Algebra.Dag
import           Database.Algebra.Dag.Common
import           Database.Algebra.SQL.Compatibility
import           Database.Algebra.SQL.Materialization.CTE
import           Database.Algebra.SQL.Util
import           Database.Algebra.Table.Lang
import           Database.Algebra.X100.Data
import           Database.Algebra.X100.Render

import           Database.DSH.Common.DBCode
import           Database.DSH.Common.QueryPlan
import           Database.DSH.VL.Vector

generateX100Queries :: QueryPlan X100Algebra NDVec -> Shape X100Code
generateX100Queries x100Plan = convertQuery $ queryShape x100Plan
 where
    m' :: NodeMap X100Algebra
    m' = nodeMap $ queryDag x100Plan

    convertQuery :: Shape NDVec -> Shape X100Code
    convertQuery (PrimVal (ADVec r' _) l)     = PrimVal (X100Code $ generateQuery m' r') $ convertLayout l
    convertQuery (ValueVector (ADVec r' _) l) = ValueVector (X100Code $ generateQuery m' r') $ convertLayout l

    convertLayout :: Layout NDVec -> Layout X100Code
    convertLayout (InColumn i)          = InColumn i
    convertLayout (Nest (ADVec r' _) l) = Nest (X100Code $ generateQuery m' r') $ convertLayout l
    convertLayout (Pair p1 p2)          = Pair (convertLayout p1) (convertLayout p2)

-- | In a query shape, render each root node for the algebraic plan
-- into a separate SQL query.

-- FIXME use materialization "prelude"
generateSqlQueries :: QueryPlan TableAlgebra NDVec -> Shape SqlCode
generateSqlQueries taPlan = renderQueryCode $ queryShape taPlan
  where
    roots = rootNodes $ queryDag taPlan
    (_sqlShared, sqlQueries) = renderOutputDSHWith PostgreSQL materialize (queryDag taPlan)
    nodeToQuery  = zip roots sqlQueries
    lookupNode n = maybe $impossible SqlCode $ lookup n nodeToQuery

    renderQueryCode :: Shape NDVec -> Shape SqlCode
    renderQueryCode shape =
        case shape of
            PrimVal (ADVec r _) lyt -> PrimVal (lookupNode r) (convertLayout lyt)
            ValueVector (ADVec r _) lyt -> ValueVector (lookupNode r) (convertLayout lyt)

    convertLayout :: Layout NDVec -> Layout SqlCode
    convertLayout lyt =
        case lyt of
            InColumn i            -> InColumn i
            Nest (ADVec r _) clyt -> Nest (lookupNode r) (convertLayout clyt)
            Pair lyt1 lyt2        -> Pair (convertLayout lyt1) (convertLayout lyt2)
