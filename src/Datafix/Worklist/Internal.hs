{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

-- |
-- Module      :  Datafix.Worklist.Internal
-- Copyright   :  (c) Sebastian Graf 2017
-- License     :  ISC
-- Maintainer  :  sgraf1337@gmail.com
-- Portability :  portable
--
-- Internal module, does not follow the PVP. Breaking changes may happen at
-- any minor version.

module Datafix.Worklist.Internal where

import           Algebra.Lattice
import           Control.Monad                    (forM_, guard, when)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State.Strict
import           Data.IORef
import           Data.Maybe                       (fromMaybe, listToMaybe,
                                                   mapMaybe)
import           Data.Proxy                       (Proxy (..))
import           Datafix.Description              hiding (datafix)
import qualified Datafix.Description
import           Datafix.IntArgsMonoSet           (IntArgsMonoSet)
import qualified Datafix.IntArgsMonoSet           as IntArgsMonoSet
import           Datafix.MonoMap                  (MonoMapKey)
import           Datafix.Utils.TypeLevel
import           Datafix.Worklist.Graph           (GraphRef, PointInfo (..))
import qualified Datafix.Worklist.Graph           as Graph
import qualified Datafix.Worklist.Graph.Dense     as DenseGraph
import qualified Datafix.Worklist.Graph.Sparse    as SparseGraph
import           System.IO.Unsafe                 (unsafePerformIO)

-- | The concrete 'MonadDependency' for this worklist-based solver.
--
-- This essentially tracks the current approximation of the solution to the
-- 'DataFlowProblem' as mutable state while 'fixProblem' makes sure we will eventually
-- halt with a conservative approximation.
newtype DependencyM domain a
  = DM (ReaderT (Env domain) IO a)
  -- ^ Why does this use 'IO'? Actually, we only need 'ST' here, but that
  -- means we have to carry around the state thread in type signatures.
  --
  -- This ultimately leaks badly into the exported interface in 'fixProblem':
  -- Since we can't have universally quantified instance contexts (yet!), we can' write
  -- @(forall s. Datafixable (DependencyM s graph domain)) => (forall s. DataFlowProblem (DependencyM s graph domain)) -> ...@
  -- and have to instead have the isomorphic
  -- @(forall s r. (Datafixable (DependencyM s graph domain) => r) -> r) -> (forall s. DataFlowProblem (DependencyM s graph domain)) -> ...@
  -- and urge all call sites to pass a meaningless 'id' parameter.
  --
  -- Also, this means more explicit type signatures as we have to make clear to
  -- the type-checker that @s@ is universally quantified in everything that
  -- touches it, e.g. @Analyses.StrAnal.LetDn.buildProblem@ from the test suite.
  --
  -- So, bottom line: We resort to 'IO' and 'unsafePerformIO' and promise not to
  -- launch missiles. In particular, we don't export 'DM' and also there
  -- must never be an instance of 'MonadIO' for this.
  deriving (Functor, Applicative, Monad)

-- | The iteration state of 'DependencyM'/'fixProblem'.
data Env domain
  = Env
  { problem          :: !(DataFlowProblem (DependencyM graph domain))
  -- ^ Constant.
  -- The specification of the data-flow problem we ought to solve.
  , iterationBound   :: !(IterationBound domain)
  -- ^ Constant.
  -- Whether to abort after a number of iterations or not.
  , callStack        :: !(IntArgsMonoSet (Products (ParamTypes domain)))
  -- ^ Contextual state.
  -- The set of points in the 'domain' of 'Node's currently in the call stack.
  , graph            :: !(Graph domain)
  -- ^ Constant ref to stateful graph.
  -- The data-flow graph, modeling dependencies between data-flow 'Node's,
  -- or rather specific points in the 'domain' of each 'Node'.
  , referencedPoints :: !(IORef (IntArgsMonoSet (Products (ParamTypes domain))))
  -- ^ Constant (but the the wrapped queue is stateful).
  -- The set of points the currently 'recompute'd node references so far.
  , unstable         :: !(IORef (IntArgsMonoSet (Products (ParamTypes domain))))
  -- ^ Constant (but the the wrapped queue is stateful).
  -- Unstable nodes that will be 'recompute'd by the 'work'list algorithm.
  }

initialEnv
  :: IntArgsMonoSet (Products (ParamTypes domain))
  -> DataFlowProblem (DependencyM domain)
  -> IterationBound domain
  -> IO (Env domain)
initialEnv unstable_ prob ib =
  Env prob ib IntArgsMonoSet.empty
    <$> Graph.new
    <*> newIORef IntArgsMonoSet.empty
    <*> newIORef unstable_
{-# INLINE initialEnv #-}

-- | A constraint synonym for the constraints 'm' and its associated
-- 'Domain' have to suffice.
--
-- This is actually a lot less scary than you might think.
-- Assuming we got [quantified class constraints](http://i.cs.hku.hk/~bruno/papers/hs2017.pdf),
-- @Datafixable@ is a specialized version of this:
--
-- @
-- type Datafixable m =
--   ( forall r. Currying (ParamTypes (Domain m)) r
--   , MonoMapKey (Products (ParamTypes (Domain m)))
--   , BoundedJoinSemiLattice (ReturnType (Domain m))
--   )
-- @
--
-- Now, let's assume a concrete @Domain m ~ String -> Bool -> Int@, so that
-- @'ParamTypes' (String -> Bool -> Int)@ expands to the type-level list @'[String, Bool]@
-- and @'Products' '[String, Bool]@ reduces to @(String, Bool)@.
--
-- Then this constraint makes sure we are able to
--
--  1.  Curry the domain of @String -> Bool -> r@ for all @r@ to e.g. @(String, Bool) -> r@.
--      See 'Currying'. This constraint should always be discharged automatically by the
--      type-checker as soon as 'ParamTypes' and 'ReturnTypes' reduce for the 'Domain' argument,
--      which happens when the concrete @'MonadDependency' m@ is known.
--
--      (Actually, we do this for multiple concrete @r@ because of the missing
--      support for quantified class constraints)
--
--  2.  We want to use a [monotone](https://en.wikipedia.org/wiki/Monotonic_function)
--      map of @(String, Bool)@ to @Int@ (the @ReturnType (Domain m)@). This is
--      ensured by the @'MonoMapKey' (String, Bool)@ constraint.
--
--      This constraint has to be discharged manually, but should amount to a
--      single line of boiler-plate in most cases, see 'MonoMapKey'.
--
--      Note that the monotonicity requirement means we have to pull non-monotone
--      arguments in @Domain m@ into the 'Node' portion of the 'DataFlowProblem'.
--
--  3.  For fixed-point iteration to work at all, the values which we iterate
--      naturally have to be instances of 'BoundedJoinSemiLattice'.
--      That type-class allows us to start iteration from a most-optimistic 'bottom'
--      value and successively iterate towards a conservative approximation using
--      the '(\/)' operator.
type Datafixable m =
  ( Currying (ParamTypes (Domain m)) (ReturnType (Domain m))
  , Currying (ParamTypes (Domain m)) (m (ReturnType (Domain m)))
  , Currying (ParamTypes (Domain m)) (ReturnType (Domain m) -> ReturnType (Domain m) -> Bool)
  , Currying (ParamTypes (Domain m)) (ReturnType (Domain m) -> ReturnType (Domain m))
  , MonoMapKey (Products (ParamTypes (Domain m)))
  , BoundedJoinSemiLattice (ReturnType (Domain m))
  )

-- | This allows us to solve @MonadDependency m => DataFlowProblem m@ descriptions
-- with 'fixProblem'.
-- The 'Domain' is extracted from a type parameter.
instance Datafixable (DependencyM domain) => MonadDependency (DependencyM domain) where
  type Domain (DependencyM domain) = domain
  datafix = datafix
  {-# INLINE datafix #-}

-- | Specifies the /density/ of the problem, e.g. whether the domain of
-- 'Node's can be confined to a finite range, in which case 'fixProblem'
-- tries to use a "Data.Vector" based graph representation rather than
-- one based on "Data.IntMap".
data Density where
  Sparse :: Density
  Dense :: Node -> Density

-- | A function that computes a sufficiently conservative approximation
-- of a point in the abstract domain for when the solution algorithm
-- decides to have iterated the node often enough.
--
-- When 'domain' is a 'BoundedMeetSemilattice'/'BoundedLattice', the
-- simplest abortion function would be to constantly return 'top'.
--
-- As is the case for 'TransferFunction' and 'ChangeDetector', this
-- carries little semantic meaning if viewed in isolation, so here
-- are a few examples for how the synonym expands:
--
-- @
--   AbortionFunction Int ~ Int -> Int
--   AbortionFunction (String -> Int) ~ String -> Int -> Int
--   AbortionFunction (a -> b -> c -> PowerSet) ~ a -> b -> c -> PowerSet -> PowerSet
-- @
--
-- E.g., the current value of the point is passed in (the tuple @(a, b, c, PowerSet)@)
-- and the function returns an appropriate conservative approximation in that
-- point.
type AbortionFunction domain
  = Arrows (ParamTypes domain) (ReturnType domain -> ReturnType domain)

-- | Aborts iteration of a value by 'const'antly returning the 'top' element
-- of the assumed 'BoundedMeetSemiLattice' of the 'ReturnType'.
abortWithTop
  :: forall domain
   . Currying (ParamTypes domain) (ReturnType domain -> ReturnType domain)
  => BoundedMeetSemiLattice (ReturnType domain)
  => AbortionFunction domain
abortWithTop =
  currys (Proxy :: Proxy (ParamTypes domain)) (Proxy :: Proxy (ReturnType domain -> ReturnType domain)) $
    const top
{-# INLINE abortWithTop #-}

-- | Expresses that iteration should or shouldn't stop after a point has
-- been iterated a finite number of times.
data IterationBound domain
  = NeverAbort
  -- ^ Will keep on iterating until a precise, yet conservative approximation
  -- has been reached. Make sure that your 'domain' satisfies the
  -- [ascending chain condition](https://en.wikipedia.org/wiki/Ascending_chain_condition),
  -- e.g. that fixed-point iteration always comes to a halt!
  | AbortAfter Int (AbortionFunction domain)
  -- ^ For when your 'domain' doesn't satisfy the ascending chain condition
  -- or when you are sensitive about solution performance.
  --
  -- The 'Int'eger determines the maximum number of iterations of a single point
  -- of a 'Node' (with which an entire function with many points may be associated)
  -- before iteration aborts in that point by calling the supplied 'AbortionFunction'.
  -- The responsibility of the 'AbortionFunction' is to find a sufficiently
  -- conservative approximation for the current value at that point.
  --
  -- When your 'ReturnType' is an instance of 'BoundedMeetSemiLattice',
  -- 'abortWithTop' might be a worthwhile option.
  -- A more sophisticated solution would trim the current value to a certain
  -- cut-off depth, depending on the first parameter, instead.

zoomIORef
  :: State s a
  -> ReaderT (IORef s) IO a
zoomIORef s = do
  ref <- ask
  uns <- lift $ readIORef ref
  let (res, uns') = runState s uns
  uns' `seq` lift $ writeIORef ref uns'
  return res
{-# INLINE zoomIORef #-}

zoomReferencedPoints
  :: State (IntArgsMonoSet (Products (ParamTypes domain))) a
  -> ReaderT (Env graph domain) IO a
zoomReferencedPoints = withReaderT referencedPoints . zoomIORef
{-# INLINE zoomReferencedPoints #-}

zoomUnstable
  :: State (IntArgsMonoSet (Products (ParamTypes domain))) a
  -> ReaderT (Env graph domain) IO a
zoomUnstable = withReaderT unstable . zoomIORef
{-# INLINE zoomUnstable #-}

enqueueUnstable
  :: k ~ Products (ParamTypes domain)
  => MonoMapKey k
  => Int -> k -> ReaderT (Env graph domain) IO ()
enqueueUnstable i k = zoomUnstable (modify' (IntArgsMonoSet.insert i k))
{-# INLINE enqueueUnstable #-}

deleteUnstable
  :: k ~ Products (ParamTypes domain)
  => MonoMapKey k
  => Int -> k -> ReaderT (Env graph domain) IO ()
deleteUnstable i k = zoomUnstable (modify' (IntArgsMonoSet.delete i k))
{-# INLINE deleteUnstable #-}

highestPriorityUnstableNode
  :: k ~ Products (ParamTypes domain)
  => MonoMapKey k
  => ReaderT (Env graph domain) IO (Maybe (Int, k))
highestPriorityUnstableNode = zoomUnstable $
  listToMaybe . IntArgsMonoSet.highestPriorityNodes <$> get
{-# INLINE highestPriorityUnstableNode #-}

withCall
  :: Datafixable (DependencyM graph domain)
  => Int
  -> Products (ParamTypes domain)
  -> ReaderT (Env graph domain) IO a
  -> ReaderT (Env graph domain) IO a
withCall node args r = ReaderT $ \env -> do
  refs <- readIORef (referencedPoints env)
  refs `seq` writeIORef (referencedPoints env) IntArgsMonoSet.empty
  ret <- runReaderT r env
    { callStack = IntArgsMonoSet.insert node args (callStack env)
    }
  writeIORef (referencedPoints env) refs
  return ret
{-# INLINE withCall #-}

-- | The first of the two major functions of this module.
--
-- 'recompute node args' iterates the value of the passed 'node'
-- at the point 'args' by invoking its 'TransferFunction'.
-- It does so in a way that respects the 'IterationBound'.
--
-- This function is not exported, and is only called by 'work'
-- and 'datafix', for when the iteration strategy decides that
-- the 'node' needs to be (and can be) re-iterated.
-- It performs tracking of which 'Node's the 'TransferFunction'
-- depended on, do that the worklist algorithm can do its magic.
recompute
  :: forall domain graph dom cod
   . dom ~ ParamTypes domain
  => cod ~ ReturnType domain
  => GraphRef graph
  => Datafixable (DependencyM graph domain)
  => Int -> Products dom -> ReaderT (Env graph domain) IO cod
recompute node args = withCall node args $ do
  prob <- asks problem
  let dom = Proxy :: Proxy dom
  let depm = Proxy :: Proxy (DependencyM graph domain cod)
  let eq = Proxy :: Proxy (cod -> cod -> Bool)
  let cod2cod = Proxy :: Proxy (cod -> cod)
  let node' = Node node
  let DM iterate' = uncurrys dom depm (dfpTransfer prob node') args
  let detectChange' = uncurrys dom eq (dfpDetectChange prob node') args
  -- We need to access the graph at three different points in time:
  --
  --    1. before the call to 'iterate', to access 'iterations', but only if abortion is required
  --    2. directly after the call to 'iterate', to get the 'oldInfo'
  --    3. And again to actually write the 'newInfo'
  --
  -- The last two can be merged, whereas it's crucial that 'oldInfo'
  -- is captured *after* the call to 'iterate', otherwise we might
  -- not pick up all 'referrers'.
  -- If abortion is required, 'maybeAbortedVal' will not be 'Nothing'.
  maybeAbortedVal <- runMaybeT $ do
    AbortAfter n abort <- lift (asks iterationBound)
    Just preInfo <- lift (withReaderT graph (Graph.lookup node args))
    guard (iterations preInfo >= n)
    Just oldVal <- return (value preInfo)
    return (uncurrys dom cod2cod abort args oldVal)
  -- For the 'Nothing' case, we proceed by iterating the transfer function.
  newVal <- maybe iterate' return maybeAbortedVal
  -- When abortion is required, 'iterate'' is not called and
  -- 'refs' will be empty, thus the node will never be marked unstable again.
  refs <- asks referencedPoints >>= lift . readIORef
  oldInfo <- withReaderT graph (Graph.updatePoint node args newVal refs)
  deleteUnstable node args
  case value oldInfo of
    Just oldVal | not (detectChange' oldVal newVal) ->
      return ()
    _ -> do
      forM_ (IntArgsMonoSet.toList (referrers oldInfo)) $
        uncurry enqueueUnstable
      when (IntArgsMonoSet.member node args refs) $
        -- This is a little unfortunate: The 'oldInfo' will
        -- not have listed the current node itself as a refererrer
        -- in case of a loop, so we have to check for
        -- that case manually in the new 'references' set.
        -- The info stored in the graph has the right 'referrers'
        -- set, though.
        enqueueUnstable node args
  return newVal
{-# INLINE recompute #-}

datafix
  :: forall domain
   . Datafixable (DependencyM domain)
  => ChangeDetector domain
  => (TransferFunction (DependencyM domain) domain -> TransferFunction (DependencyM domain) domain)
  -> TransferFunction (DependencyM domain) domain
datafix cd f = currys dom cod impl
  where
    dom = Proxy :: Proxy (ParamTypes domain)
    cod = Proxy :: Proxy (DependencyM domain (ReturnType domain))
    impl args = DM $ do
      node <- withReaderT graph (Graph.allocateNode cd (f . currys dom cod . dependOn))
      dependOn node args
{-# INLINE datafix #-}

dependOn
  :: forall domain
   . Datafixable (DependencyM domain)
  => Node
  -> Product (ParamTypes domain)
  -> DependencyM domain (ReturnType domain)
dependOn node args = DM $ do
  cycleDetected <- IntArgsMonoSet.member node args <$> asks callStack
  isStable <- zoomUnstable $
    not . IntArgsMonoSet.member node args <$> get
  maybePointInfo <- withReaderT graph (Graph.lookup node args)
  zoomReferencedPoints (modify' (IntArgsMonoSet.insert node args))
  case maybePointInfo >>= value of
    -- 'value' can only be 'Nothing' if there was a 'cycleDetected':
    -- Otherwise, the node wasn't part of the call stack and thus will either
    -- have a 'value' assigned or will not have been discovered at all.
    Nothing | cycleDetected ->
      -- Somewhere in an outer activation record we already compute this one.
      -- We don't recurse again and just return an optimistic approximation,
      -- such as 'bottom'.
      -- Otherwise, 'recompute' will immediately add a 'PointInfo' before
      -- any calls to 'datafix' for a cycle to even be possible.
      optimisticApproximation node args
    Just val | isStable || cycleDetected ->
      -- No brainer
      return val
    maybeVal ->
      -- No cycle && (unstable || undiscovered). Apply one of the schemes
      -- outlined in
      -- https://github.com/sgraf812/journal/blob/09f0521dbdf53e7e5777501fc868bb507f5ceb1a/datafix.md.html#how-an-algorithm-that-can-do-3-looks-like
      scheme2 maybeVal node args
{-# INLINE dependOn #-}

-- | Compute an optimistic approximation for a point of a given node that is
-- as precise as possible, given the other points of that node we already
-- computed.
--
-- E.g., it is always valid to return 'bottom' from this, but in many cases
-- we can be more precise since we possibly have computed points for the node
-- that are lower bounds to the current point.
optimisticApproximation
  :: GraphRef graph
  => Datafixable (DependencyM graph domain)
  => Int -> Products (ParamTypes domain) -> ReaderT (Env graph domain) IO (ReturnType domain)
optimisticApproximation node args = do
  points <- withReaderT graph (Graph.lookupLT node args)
  -- Note that 'points' might contain 'PointInfo's that have no 'value'.
  -- It's OK to filter these out: At worst, the approximation will be
  -- more optimistic than necessary.
  return (joins (mapMaybe (value . snd) points))

scheme1, scheme2
  :: GraphRef graph
  => Datafixable (DependencyM graph domain)
  => Maybe (ReturnType domain)
  -> Int
  -> Products (ParamTypes domain)
  -> ReaderT (Env graph domain) IO (ReturnType domain)
{-# INLINE scheme1 #-}
{-# INLINE scheme2 #-}

-- | scheme 1 (see https://github.com/sgraf812/journal/blob/09f0521dbdf53e7e5777501fc868bb507f5ceb1a/datafix.md.html#how-an-algorithm-that-can-do-3-looks-like).
--
-- Let the worklist algorithm figure things out.
scheme1 maybeVal node args =
  case maybeVal of
    Nothing -> do
      enqueueUnstable node args
      optimisticApproximation node args
    Just val ->
      return val

-- | scheme 2 (see https://github.com/sgraf812/journal/blob/09f0521dbdf53e7e5777501fc868bb507f5ceb1a/datafix.md.html#how-an-algorithm-that-can-do-3-looks-like).
--
-- Descend into \(\bot\) nodes when there is no cycle to discover the set of
-- reachable nodes as quick as possible.
-- Do *not* descend into unstable, non-\(\bot\) nodes.
scheme2 maybeVal node args =
  case maybeVal of
    Nothing ->
      -- Depth-first discovery of reachable nodes
      recompute node args
    Just val ->
      -- It is unclear if this really is beneficial:
      -- We don't discover any new nodes and should rather
      -- rely on the ordering in the worklist.
      return val

-- There used to be a third scheme that is no longer possible with the current
-- mode of dependency tracking.
-- See https://github.com/sgraf812/journal/blob/09f0521dbdf53e7e5777501fc868bb507f5ceb1a/datafix.md.html#how-an-algorithm-that-can-do-3-looks-like

-- |As long as the supplied "Maybe" expression returns "Just _", the loop
-- body will be called and passed the value contained in the 'Just'.  Results
-- are discarded.
--
-- Taken from 'Control.Monad.Loops.whileJust_'.
whileJust_ :: Monad m => m (Maybe a) -> (a -> m b) -> m ()
whileJust_ cond action = go
  where
    go = cond >>= \case
      Nothing -> return ()
      Just a  -> action a >> go
{-# INLINE whileJust_ #-}

-- | Defined as 'work = whileJust_ highestPriorityUnstableNode (uncurry recompute)'.
--
-- Tries to dequeue the 'highestPriorityUnstableNode' and 'recompute's the value of
-- one of its 'unstable' points, until the worklist is empty, indicating that a
-- fixed-point has been reached.
work
  :: GraphRef graph
  => Datafixable (DependencyM graph domain)
  => ReaderT (Env graph domain) IO ()
work = whileJust_ highestPriorityUnstableNode (uncurry recompute)
{-# INLINE work #-}

-- | Computes a solution to the described 'DataFlowProblem' by iterating
-- 'TransferFunction's until a fixed-point is reached.
--
-- It does do by employing a worklist algorithm, iterating unstable 'Node's
-- only.
-- 'Node's become unstable when the point of another 'Node' their 'TransferFunction'
-- 'datafix'ed changed.
--
-- The sole initially unstable 'Node' is the last parameter, and if your
-- 'domain' is function-valued (so the returned 'Arrows' expands to a function),
-- then any further parameters specify the exact point in the 'Node's transfer
-- function you are interested in.
fixProblem
  :: forall domain
   . Datafixable (DependencyM domain)
  => DataFlowProblem (DependencyM domain)
  -- ^ The description of the @DataFlowProblem@ to solve.
  -> Density
  -- ^ Describes if the algorithm is free to use a 'Dense', 'Vector'-based
  -- graph representation or has to go with a 'Sparse' one based on 'IntMap'.
  -> IterationBound domain
  -- ^ Whether the solution algorithm should respect a maximum bound on the
  -- number of iterations per point. Pass 'NeverAbort' if you don't care.
  -> Arrows (ParamTypes domain) (ReturnType domain)
fixProblem prob density ib (Node node) = currys (Proxy :: Proxy (ParamTypes domain)) (Proxy :: Proxy (ReturnType domain)) impl
  where
    impl
      = fromMaybe (error "Broken invariant: The root node has no value")
      . (>>= value)
      . runProblem
    runProblem args = unsafePerformIO $ do
      -- Trust me, I'm an engineer! See the docs of the 'DM' constructor
      -- of 'DependencyM' for why we 'unsafePerformIO'.
      env <- initialEnv (IntArgsMonoSet.singleton node args) prob ib
      runReaderT (work >> withReaderT graph (Graph.lookup node args)) env
{-# INLINE fixProblem #-}
