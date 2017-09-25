{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Critical (tests) where

import           Algebra.Lattice
import           Data.Proxy
import           Datafix
import           Datafix.Worklist (Density (..), IterationBound (..),
                                   fixProblem)
import           Numeric.Natural
import           Test.Tasty
import           Test.Tasty.HUnit

instance JoinSemiLattice Natural where
  (\/) = max

instance BoundedJoinSemiLattice Natural where
  bottom = 0

fixLoop density n = fixProblem loopProblem (density (Node 0)) NeverAbort (Node n)
fixDoubleDependency density n = fixProblem doubleDependencyProblem (density (Node 1)) NeverAbort (Node n)

tests :: [TestTree]
tests =
  [ testGroup "One node with loop"
      [ testGroup "Sparse"
          [ testCase "stabilises at 10" (fixLoop (const Sparse) 0 @?= 10)
          ]
      , testGroup "Dense"
          [ testCase "stabilises at 10" (fixLoop Dense 0 @?= 10)
          ]
      ]
  , testGroup "One node with double dependency on node with loop"
      [ testGroup "Sparse"
          [ testCase "stabilizes at 4" (fixDoubleDependency (const Sparse) 0 @?= 4)
          ]
      , testGroup "Dense"
          [ testCase "stabilizes at 4" (fixDoubleDependency Dense 0 @?= 4)
          ]
      ]
  ]

mkDFP :: forall m . (MonadDependency m, Domain m ~ Natural) => (Node -> TransferFunction m Natural) -> DataFlowProblem m
mkDFP transfer = DFP transfer (const (eqChangeDetector (Proxy :: Proxy m)))

-- | One node graph with loop that stabilizes after 10 iterations.
loopProblem :: forall m . (MonadDependency m, Domain m ~ Natural) => DataFlowProblem m
loopProblem = mkDFP transfer
  where
    transfer (Node 0) = do -- stabilizes at 10
      n <- dependOn (Proxy :: Proxy m) (Node 0)
      return (min (n + 1) 10)

-- | Two node graph (nodes @A@, @B@), where @A@ `dependOn` @B@ twice and @B@
-- has a loop.
--
-- The idea here is that the second change of @B@ from 1 to 2 makes @A@
-- unstable, so that it gets iterated again, which results in a value of
-- 4 instead of e.g. 3 (= 1 + 2, the values of @B@ in the first iteration
-- of @A@).
doubleDependencyProblem :: forall m . (MonadDependency m, Domain m ~ Natural) => DataFlowProblem m
doubleDependencyProblem = mkDFP transfer
  where
    p :: Proxy m
    p = Proxy
    transfer (Node 0) = do -- stabilizes at 4
      n <- dependOn p (Node 1)
      m <- dependOn p (Node 1)
      return (n + m)
    transfer (Node 1) = do -- stabilizes at 2
      n <- dependOn p (Node 1)
      return (min (n + 1) 2)
