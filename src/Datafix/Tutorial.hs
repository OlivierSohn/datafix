{-# OPTIONS_GHC -fno-warn-unused-imports #-}

-- |
-- Module      :  Datafix.Tutorial
-- Copyright   :  (c) Sebastian Graf 2018
-- License     :  ISC
-- Maintainer  :  sgraf1337@gmail.com
-- Portability :  portable
--
-- = What is This?
--
-- The purpose of @datafix@ is to separate declaring
-- [data-flow problems](https://en.wikipedia.org/wiki/Data-flow_analysis)
-- from computing their solutions by
-- [fixed-point iteration](https://en.wikipedia.org/wiki/Fixed-point_iteration).
--
-- The need for this library arose when I was combining two analyses
-- within GHC for my master's thesis. I recently
-- [held a talk](https://cdn.rawgit.com/sgraf812/hiw17/2645b206d3f2b5e6e7c95bc791dfa4bf9cbc8d12/slides.pdf)
-- on that topic, feel free to click through if you want to know the details.
--
-- You can think of data-flow problems as problems that are solvable by
-- [dynamic programming](https://en.wikipedia.org/wiki/Dynamic_programming)
-- or [memoization](https://en.wikipedia.org/wiki/Memoization),
-- except that the dependency graph of data-flow problems doesn't need to be
-- acyclic.
--
-- Data-flow problems are declared with the primitives in
-- @"Datafix.Description"@ and solved by @Datafix.Worklist.'solveProblem'@.
--
-- With that out of the way, let's set in place the GHCi environment of our
-- examples:
--
-- >>> :set -XScopedTypeVariables
-- >>> :set -XTypeApplications
-- >>> :set -XTypeFamilies
-- >>> import Datafix
-- >>> import Data.Proxy (Proxy (..))
-- >>> import Algebra.Lattice (JoinSemiLattice (..), BoundedJoinSemiLattice (..))
-- >>> import Numeric.Natural
--
-- = Use Case: Solving Recurrences
--
-- Let's start out by computing the fibonacci series:
--
-- >>> :{
--   fib :: Natural -> Natural
--   fib 0 = 0
--   fib 1 = 1
--   fib n = fib (n-1) + fib (n-2)
-- :}
--
-- >>> fib 3
-- 2
-- >>> fib 10
-- 55
--
-- Bring your rabbits to the vet while you can still count them...
--
-- Anyway, the fibonacci series is a typical problem exhibiting
-- /overlapping subproblems/. As a result, our @fib@ function from above scales badly in
-- the size of its input argument @n@. Because we repeatedly recompute
-- solutions, the time complexity of our above function is in \(\mathcal{O}(2^n)\)!
--
-- We can do better by using /dynamic programming/ or /memoization/ to keep a
-- cache of already computed sub-problems, which helps computing the \(n\)th
-- item in \(\mathcal{O}(n)\) time and space:
--
-- >>> :{
--   fib2 :: Natural -> Natural
--   fib2 n = fibs !! fromIntegral n
--     where
--       fibs = 0 : 1 : zipWith (+) fibs (tail fibs)
-- :}
--
-- >>> fib2 3
-- 2
-- >>> fib2 10
-- 55
--
-- That's one of Haskell's pet issues: Expressing dynamic programs as lists
-- through laziness.
--
-- As promised in the previous section, we can do the same using @datafix@.
-- First, we need to declare a /transfer function/ that makes the data
-- dependencies for the recursive case explicit, as if we were using
-- 'Data.Function.fix' to eliminate the recursion:
--
-- >>> :{
--   transferFib
--     :: forall m
--      . (MonadDependency m, Domain m ~ Natural)
--     => Node
--     -> LiftedFunc Natural m
--   transferFib (Node 0) = return 0
--   transferFib (Node 1) = return 1
--   transferFib (Node n) = do
--     a <- dependOn @m (Node (n-1))
--     b <- dependOn @m (Node (n-2))
--     return (a + b)
-- :}
--
-- 'MonadDependency' contains a single primitive 'dependOn' for that purpose.
--
-- Every point of the fibonacci series is modeled as a seperate 'Node' of the
-- data-flow graph.
-- By looking at the definition of 'LiftedFunc', we can see that
-- @LiftedFunc Natural m ~ m Natural@, so for our simple
-- 'Natural' 'Domain', the transfer function is specified directly in
-- 'MonadDependency'.
--
-- Note that indeed we eliminated explicit recursion in @transferFib@.
-- This allows the solution algorithm to track and discover dependencies
-- of the transfer function as it is executed!
--
-- With our transfer function (which denotes data-flow nodes in the semantics
-- of 'Natural's) in place, we can construct a 'DataFlowProblem':
--
-- >>> :{
--   fibDfp :: forall m . (MonadDependency m, Domain m ~ Natural) => DataFlowProblem m
--   fibDfp = DFP transferFib (const (eqChangeDetector @(Domain m)))
-- :}
--
-- The 'eqChangeDetector' is important for cyclic dependency graphs and makes
-- sure we detect when a fixed-point has been reached.
--
-- That's it for describing the data-flow problem of fibonacci numbers.
-- We can ask @Datafix.Worklist.'solveProblem'@ for a solution in a minute.
--
-- The 'solveProblem' solver demands an instance of 'BoundedJoinSemiLattice'
-- on the 'Domain' for when the data-flow graph is cyclic. We conveniently
-- delegate to the total @Ord@ instance for 'Numeric.Natural.Natural', knowing
-- that its semantic interpretation is irrelevant to us:
--
-- >>> instance JoinSemiLattice Natural where (\/) = max
-- >>> instance BoundedJoinSemiLattice Natural where bottom = 0
--
-- And now the final incantation of the solver:
--
-- >>> solveProblem fibDfp Sparse NeverAbort (Node 10)
-- 55
--
-- This will also execute in \(\mathcal{O}(n)\) space and time, all without
-- worrying about a smart solution strategy involving how to tie knots or
-- allocate vectors.
-- Granted, this doesn't really pay off for simple problems like computing
-- fibonacci numbers because of the boilerplate involved and the somewhat
-- devious type-level story, but the intended use case is that of static
-- analysis of programming languages.
--
-- Before I delegate you to a blog post about strictness analysis,
-- we will look at a more devious reccurence relation with actual
-- cycles in the resulting data-flow graph.
--
-- = Use Case: Solving Cyclic Recurrences
--
-- The recurrence relation describing fibonacci numbers admits a clear
-- plan of how to compute a solution, because the dependency graph is
-- obviously acyclic: To compute the next new value of the sequence,
-- only the prior two values are needed.
--
-- This is not true of the following reccurence relation:
--
-- \[
-- f(n) = \begin{cases}
--   2 \cdot f(\frac{n}{2}), & n \text{ even}\\
--   f(n+1)-1, & n \text{ odd}
-- \end{cases}
-- \]
--
-- The identity function is the only solution to this, but it is unclear
-- how we could arrive at that conclusion just by translating that relation
-- into Haskell:
--
-- >>> :{
-- f n
--   | even n = 2 * f (n `div` 2)
--   | odd n  = f (n + 1) - 1
-- :}
--
-- Imagine a call @f 1@: This will call @f 2@ recursively, which again
-- will call @f 1@. We hit a cyclic dependency!
--
-- Fortunately, we can use @datafix@ to compute the solution by fixed-point
-- iteration (which assumes monotonicity of the function to approximate):
--
-- >>> :{
--   transferF
--     :: forall m
--      . (MonadDependency m, Domain m ~ Int)
--     => Node
--     -> LiftedFunc Int m
--   transferF (Node n)
--     | even n = (* 2) <$> dependOn @m (Node (n `div` 2))
--     | odd n  = (subtract 1) <$> dependOn @m (Node (n + 1))
-- :}
--
-- >>> :{
--   fDfp :: forall m . (MonadDependency m, Domain m ~ Int) => DataFlowProblem m
--   fDfp = DFP transferF (const (eqChangeDetector @(Domain m)))
-- :}
--
-- Specification of the data-flow problem works the same as for the 'fib'
-- function.
--
-- As for 'Natural', we need an instance of 'BoundedJoinSemiLattice'
-- for 'Int' to compute a solution:
--
-- >>> instance JoinSemiLattice Int where (\/) = max
-- >>> instance BoundedJoinSemiLattice Int where bottom = minBound
--
-- Now it's just a matter of calling 'solveProblem' with the right parameters:
--
-- >>> solveProblem fDfp Sparse NeverAbort (Node 0)
-- 0
-- >>> solveProblem fDfp Sparse NeverAbort (Node 5)
-- 5
-- >>> solveProblem fDfp Sparse NeverAbort (Node 42)
-- 42
-- >>> solveProblem fDfp Sparse NeverAbort (Node (-10))
-- -10
--
-- Note how the /specification/ of the data-flow problem was as unexciting as
-- it was for the fibonacci sequence (modulo boilerplate), yet the recurrence
-- we solved was pretty complicated already.
--
-- Of course, encoding the identity function this way is inefficient.
-- But keep in mind that in general, we don't know the solution to a particular
-- recurrence! It's always possible to solve the recurrence by hand upfront,
-- but that's trading precious developer time for what might be a throw-away
-- problem anyway.
--
-- Which brings us to the prime and final use case...
--
-- = Use Case: Static Analysis
--
-- Recurrence equations occur /all the time/ in denotational
-- semantics and static data-flow analysis.
--
-- For every invocation of the compiler, for every module, for every analysis
-- within the compiler, a recurrence relation representing program semantics
-- is to be solved. Naturally, we can't task a human with solving a buch of
-- complicated recurrences everytime we hit compile.
--
-- In the imperative world, it's common-place to have some kind of fixed-point
-- iteration framework carry out the iteration of the data-flow graph, but
-- I could not find a similar abstraction for functional programming languages
-- yet. Analyses for functional languages are typically carried out as iterated
-- traversals of the syntax tree, but that is unsatisfying for a number of
-- reasons:
--
--  1.  Solution logic of the data-flow problem is intertwined with its
--      specification.
--  2.  Solution logic is duplicated among multiple analyses, violating DRY.
--  3.  A consequence of the last two points is that performance tweaks
--      have to be adapted for every analysis separately.
--      In the case of GHC's Demand Analyser, going from chaotic iteration
--      (which corresponds to naive iterated tree traversals) to an iteration
--      scheme that caches results of inner let-bindings, annotations to the
--      syntax tree are suddenly used like 'State' threads, which makes
--      the analysis logic even more complex than it already was.
--
-- So, I can only encourage any compiler dev who wants to integrate static
-- analyses into their compiler to properly specify the data-flow problems
-- in terms of @datafix@ and leave the intricacies of finding a good iteration
-- order to this library :)
--
-- For a principled approach of how to do that, read this blog post on the
-- matter TODO, where I discuss how to do a simple strictness analysis on GHC
-- Core.

module Datafix.Tutorial () where

import           Datafix
