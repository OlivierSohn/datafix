{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}

module Analyses.StrAnal.Arity where

import           Algebra.Lattice
import           Algebra.Lattice.Op
import           Algebra.PartialOrd
import           Control.Arrow      (second)
import           Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import           Data.Maybe         (maybeToList)
import           GHC.Exts           (coerce)

import           Datafix.MonoMap

-- | Arity is totally ordered, but with the order turned
-- upside down. E.g., 'Arity 0' is the figurative 'top'
-- element and the instance for 'JoinSemiLattice' will
-- return the minimum of the two arities.
--
-- This corresponds to the intuition that more incoming
-- arguments is more valuable information to the analysis.
newtype Arity
  = Arity Int
  deriving (Eq, Num)

instance Show Arity where
  show (Arity i) = show i

instance Ord Arity where
  compare (Arity a) (Arity b) = compare (Op a) (Op b)

instance PartialOrd Arity where
  leq a b = a <= b

instance JoinSemiLattice Arity where
  Arity a \/ Arity b = Arity (min a b)

instance MeetSemiLattice Arity where
  Arity a /\ Arity b = Arity (max a b)

newtype ArityMap v
  = ArityMap (IntMap v)
  deriving (Eq, Show, Foldable)

-- | This can use an efficient 'IntMap' representation instead of the default
-- implementation using 'POMap'.
--
-- We must be careful with the 'Op' ordering, though.
instance MonoMapKey Arity where
  type MonoMap Arity = ArityMap
  empty = ArityMap IntMap.empty
  singleton (Arity n) v = ArityMap (IntMap.singleton n v)
  insert (Arity n) v (ArityMap m) = ArityMap (IntMap.insert n v m)
  delete (Arity n) (ArityMap m) = ArityMap (IntMap.delete n m)
  lookup (Arity n) (ArityMap m) = IntMap.lookup n m
  -- using GE here!
  lookupLE (Arity n) (ArityMap m) = coerce (maybeToList (IntMap.lookupGE n m))
  -- maxview!
  lookupMin (ArityMap m) = coerce (maybeToList (fst <$> IntMap.maxViewWithKey m))
  difference (ArityMap a) (ArityMap b) = ArityMap (IntMap.difference a b)
  keys (ArityMap m) = coerce (IntMap.keys m)
  insertLookupWithKey f (Arity n) v (ArityMap m) =
    coerce (IntMap.insertLookupWithKey (coerce f) n v m)
  alter f (Arity n) (ArityMap m) = ArityMap (IntMap.alter (coerce f) n m)
