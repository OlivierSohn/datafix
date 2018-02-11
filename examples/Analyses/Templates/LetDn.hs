{-# LANGUAGE AllowAmbiguousTypes   #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# OPTIONS_GHC -fexpose-all-unfoldings #-}

-- | This module provides a template for backward analyses in the style of
-- GHC's projection-based strictness analysis. Defining property is the way
-- in which let-bindings are handled: Strictness types are unleashed at call
-- sites depending on incoming argument strictness.
--
-- The idea is that users of this module only need to provide a
-- 'TransferAlgebra' for 'buildProblem' to get a specification for the desired
-- data-flow problem. Remarkably, 'buildProblem' completely abstracts away
-- recursive bindings: The passed 'TransferAlgebra' is non-recursive and thus
-- doesn't need to do any allocation of 'Node's or calls to 'dependOn'.
-- As a result, 'TransferAlgebra's operate in a clean @forall m. Monad m@
-- constraint, guaranteeing purity.

module Analyses.Templates.LetDn
  ( TransferAlgebra
  , buildProblem
  ) where

import           Data.Primitive.Array     (indexArray, sizeofArray)
import           Data.Proxy               (Proxy (..))

import           Analyses.Syntax.CoreSynF
import           Datafix

import           CoreSyn
import           VarEnv

-- | A 'TransferAlgebra' for a given @lattice@ interprets a single layer of
-- 'CoreExprF' in terms of a 'LiftFunc lattice m', for any possible
-- @'Monad' m@. It has access to a 'VarEnv' of 'LiftFunc's for every
-- free variable in the expression in order to do so.
--
-- The suffix @Algebra@ is inspired by recursion schemes. 'TransferAlgebra's
-- are <F-algebras https://en.wikipedia.org/wiki/F-algebra>, where the
-- /base functor/ is 'CoreExprF' and the /carrier/ is
-- @LiftFunc lattice m@.
--
-- By the same analogy, 'buildProblem' is the associated recursion scheme.
type TransferAlgebra lattice
  = forall m
   . Monad m
  => Proxy m
  -> Proxy lattice
  -> VarEnv (LiftFunc lattice m)
  -> CoreExprF (LiftFunc lattice m)
  -> LiftFunc lattice m

-- | Given a 'TransferAlgebra', this function takes care of building a
-- 'DataFlowProblem' for 'CoreExpr's.
-- It allocates 'Node's and ties knots for recursive bindings
-- through calls to 'dependOn'. These are then hidden in a 'VarEnv'
-- and passed on to the 'TransferAlgebra', which can stay completely
-- agnostic of node allocation and 'MonadDependency' this way.
--
-- It returns the root 'Node', denoting the passed expression, and the maximum
-- allocated 'Node', which allows to configure 'fixProblem' with a dense
-- 'GraphRep'. The final return value is the 'DataFlowProblem' reflecting
-- the analysis specified by the 'TransferAlgebra' applied to the given
-- 'CoreExpr'.
--
-- Continuing the recursion schemes analogy from 'TransferAlgebra',
-- 'buildProblem' is a recursion scheme. Applying it to a 'TransferAlgebra'
-- yields a catamorphism. It is special in that recursive let-bindings
-- lead to non-structural recursion, so termination isn't obvious and
-- demands some confidence in domain theory by the programmer.
buildProblem
  :: forall m
   . MonadDependency m
  => TransferAlgebra (Domain m)
  -> CoreExpr
  -> DataFlowProblem m
buildProblem alg e = DFP (transfer emptyVarEnv e)
  where
    p = Proxy :: Proxy m
    alg = alg' p (Proxy :: Proxy (Domain m))
    transfer env = \case
      Lit lit -> alg env (LitF lit)
      Var id_ -> alg env (VarF id_)
      Type ty -> alg env (TypeF ty)
      Coercion co -> alg env (CoercionF co)
      Cast e co -> alg env (CastF (transfer env e) co)
      Tick t e -> alg env (TickF t (transfer env e))
      App f a -> alg env (AppF (transfer env f) (transfer env a))
      Lam id_ body -> alg env (LamF id_ (transfer env body))
      Case scrut bndr ty alts ->
        alg env (CaseF (transfer env scrut) bndr ty (transferAlts env alts))
      -- Note that we pass the old env to 'alg'.
      -- 'alg' should use 'transferredBind' for
      -- annotated RHSs.
      Let bind body
        | (env', transferredBind) <- registerBindingGroup env bind
        -> alg env (LetF transferredBind (transfer env' body))
    {-# INLINE transfer #-}

{-# INLINE buildProblem #-}

type TF m = LiftFunc (Domain m) m

datafixTransferAlgebra
  :: forall m
   . MonadDependency m
  => Proxy m
  -> TransferAlgebra (Domain m)
  -> CoreExpr
  -> TF m
datafixTransferAlgebra p alg' = buildExpr emptyVarEnv
  where
    alg = alg' p (Proxy :: Proxy (Domain m))
    buildExpr
      :: VarEnv (TF m)
      -> CoreExpr
      -> NodeAllocator (TF m) (TF m)
    buildExpr env expr =
      case expr of
        Lit lit -> pure (alg env (LitF lit))
        Var id_ -> pure (alg env (VarF id_))
        Type ty -> pure (alg env (TypeF ty))
        Coercion co -> pure (alg env (CoercionF co))
        Cast e co -> do
          transferE <- buildExpr env e
          pure (alg env (CastF transferE co))
        Tick t e -> do
          transferE <- buildExpr env e
          pure (alg env (TickF t transferE))
        App f a -> do
          transferF <- buildExpr env f
          transferA <- buildExpr env a
          pure (alg env (AppF transferF transferA))
        Lam id_ body -> do
          transferBody <- buildExpr env body
          pure (alg env (LamF id_ transferBody))
        Case scrut bndr ty alts -> do
          transferScrut <- buildExpr env scrut
          transferAlts <- mapM (buildAlt env) alts
          pure (alg env (CaseF transferScrut bndr ty transferAlts))
        Let bind body -> do
          (env', transferredBind) <- registerBindingGroup env bind
          transferBody <- buildExpr env' body
          -- Note that we pass the old env to 'alg'.
          -- 'alg' should use 'transferredBind' for
          -- annotated RHSs.
          pure (alg env (LetF transferredBind transferBody))
    {-# INLINE buildExpr #-}

    buildAlt env (con, bndrs, e) = do
      transferE <- buildExpr env e
      pure (con, bndrs, transferE)
    {-# INLINE buildAlt #-}

    mapBinders f env bind = do
      let binders = flattenBinds [bind]
      (env', transferredBinds) <- f env binders
      case bind of
        Rec{} -> pure (env', RecF transferredBinds)
        NonRec{}
          | [(id_, transferRHS)] <- transferredBinds
          -> pure (env', NonRecF id_ transferRHS)
        _ -> error "NonRec, but multiple transferredBinds"
    {-# INLINE mapBinders #-}


    registerBindingGroup = mapBinders impl
      where
        impl env binders =
          case binders of
            [] -> pure (env, [])
            ((id_, rhs):binders') ->
              allocateNode $ \node -> do
                -- This block is where we tie the knot through
                -- 'MonadDependency'!
                let deref = dependOn p node
                let env' = extendVarEnv env id_ deref
                (env'', transferredBind) <- impl env' binders'
                transferRHS <- buildExpr env' rhs
                -- we return `deref`, which is like `transferRHS` but
                -- with caching.
                pure ((env'', (id_, deref):transferredBind), transferRHS)
    {-# INLINE registerBindingGroup #-}
{-# INLINE datafixTransferAlgebra #-}
