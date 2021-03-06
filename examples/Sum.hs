{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}

module Sum where

import           Datafix
import           Numeric.Natural

sumProblem :: forall m . (MonadDependency m, Domain m ~ Natural) => DataFlowProblem m
sumProblem = DFP transfer (const (eqChangeDetector @(Domain m)))
  where
    transfer :: Node -> LiftedFunc Natural m
    transfer (Node 0) = return 0
    transfer (Node n) = do
      a <- dependOn @m (Node (n-1))
      return (fromIntegral n + a)
