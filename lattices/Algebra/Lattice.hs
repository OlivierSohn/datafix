{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE Safe               #-}
#if __GLASGOW_HASKELL__ >= 707 && __GLASGOW_HASKELL__ < 709
{-# OPTIONS_GHC -fno-warn-amp #-}
#endif
----------------------------------------------------------------------------
-- |
-- Module      :  Algebra.Lattice
-- Copyright   :  (C) 2010-2015 Maximilian Bolingbroke
-- License     :  BSD-3-Clause (see the file LICENSE)
--
-- Maintainer  :  Oleg Grenrus <oleg.grenrus@iki.fi>
--
-- In mathematics, a lattice is a partially ordered set in which every
-- two elements have a unique supremum (also called a least upper bound
-- or @join@) and a unique infimum (also called a greatest lower bound or
-- @meet@).
--
-- In this module lattices are defined using 'meet' and 'join' operators,
-- as it's constructive one.
--
----------------------------------------------------------------------------
module Algebra.Lattice (
    -- * Unbounded lattices
    JoinSemiLattice(..), MeetSemiLattice(..), Lattice,
    joinLeq, meetLeq,

    -- * Bounded lattices
    BoundedJoinSemiLattice(..), BoundedMeetSemiLattice(..), BoundedLattice,
    joins, meets,
    fromBool,

    -- * Monoid wrappers
    Meet(..), Join(..),

    -- * Fixed points of chains in lattices
    lfp, lfpFrom, unsafeLfp,
    gfp, gfpFrom, unsafeGfp,
  ) where

import qualified Algebra.PartialOrd    as PO

import           Control.Monad.Zip     (MonadZip (..))
import           Data.Data             (Data, Typeable)
import           Data.Proxy            (Proxy (..))
import           Data.Semigroup        (All (..), Any (..), Endo (..),
                                        Semigroup (..))
import           Data.Void             (Void)
import           GHC.Generics          (Generic)

import qualified Data.IntMap           as IM
import qualified Data.IntSet           as IS
import qualified Data.Map              as M
import qualified Data.Set              as S

import           Control.Applicative   (Const (..))
import           Data.Functor.Identity (Identity (..))

infixr 6 /\ -- This comment needed because of CPP
infixr 5 \/

-- | A algebraic structure with element joins: <http://en.wikipedia.org/wiki/Semilattice>
--
-- > Associativity: x \/ (y \/ z) == (x \/ y) \/ z
-- > Commutativity: x \/ y == y \/ x
-- > Idempotency:   x \/ x == x
class JoinSemiLattice a where
    (\/) :: a -> a -> a
    (\/) = join

    join :: a -> a -> a
    join = (\/)

#if __GLASGOW_HASKELL__ >= 707
    {-# MINIMAL (\/) | join #-}
#endif
{-# DEPRECATED join "Use '\\/' infix operator" #-}

-- | The partial ordering induced by the join-semilattice structure
joinLeq :: (Eq a, JoinSemiLattice a) => a -> a -> Bool
joinLeq x y = (x \/ y) == y

-- | A algebraic structure with element meets: <http://en.wikipedia.org/wiki/Semilattice>
--
-- > Associativity: x /\ (y /\ z) == (x /\ y) /\ z
-- > Commutativity: x /\ y == y /\ x
-- > Idempotency:   x /\ x == x
class MeetSemiLattice a where
    (/\) :: a -> a -> a
    (/\) = meet

    meet :: a -> a -> a
    meet = (/\)

#if __GLASGOW_HASKELL__ >= 707
    {-# MINIMAL (/\) | meet #-}
#endif
{-# DEPRECATED meet "Use '/\\' infix operator" #-}

-- | The partial ordering induced by the meet-semilattice structure
meetLeq :: (Eq a, MeetSemiLattice a) => a -> a -> Bool
meetLeq x y = (x /\ y) == x



-- | The combination of two semi lattices makes a lattice if the absorption law holds:
-- see <http://en.wikipedia.org/wiki/Absorption_law> and <http://en.wikipedia.org/wiki/Lattice_(order)>
--
-- > Absorption: a \/ (a /\ b) == a /\ (a \/ b) == a
class (JoinSemiLattice a, MeetSemiLattice a) => Lattice a where

-- | A join-semilattice with some element |bottom| that \/ approaches.
--
-- > Identity: x \/ bottom == x
class JoinSemiLattice a => BoundedJoinSemiLattice a where
    bottom :: a

-- | The join of a list of join-semilattice elements
joins :: (BoundedJoinSemiLattice a, Foldable f) => f a -> a
joins = getJoin . foldMap Join

-- | A meet-semilattice with some element |top| that /\ approaches.
--
-- > Identity: x /\ top == x
class MeetSemiLattice a => BoundedMeetSemiLattice a where
    top :: a

-- | The meet of a list of meet-semilattice elements
meets :: (BoundedMeetSemiLattice a, Foldable f) => f a -> a
meets = getMeet . foldMap Meet

-- | Lattices with both bounds
class (Lattice a, BoundedJoinSemiLattice a, BoundedMeetSemiLattice a) => BoundedLattice a where

-- | 'True' to 'top' and 'False' to 'bottom'
fromBool :: BoundedLattice a => Bool -> a
fromBool True  = top
fromBool False = bottom

--
-- Sets
--

instance Ord a => JoinSemiLattice (S.Set a) where
    (\/) = S.union

instance Ord a => MeetSemiLattice (S.Set a) where
    (/\) = S.intersection

instance Ord a => Lattice (S.Set a) where

instance Ord a => BoundedJoinSemiLattice (S.Set a) where
    bottom = S.empty

--
-- IntSets
--

instance JoinSemiLattice IS.IntSet where
    (\/) = IS.union

instance MeetSemiLattice IS.IntSet where
    (/\) = IS.intersection

instance Lattice IS.IntSet

instance BoundedJoinSemiLattice IS.IntSet where
    bottom = IS.empty

--
-- Maps
--

instance (Ord k, JoinSemiLattice v) => JoinSemiLattice (M.Map k v) where
    (\/) = M.unionWith (\/)

instance (Ord k, MeetSemiLattice v) => MeetSemiLattice (M.Map k v) where
    (/\) = M.intersectionWith (/\)

instance (Ord k, Lattice v) => Lattice (M.Map k v) where

instance (Ord k, JoinSemiLattice v) => BoundedJoinSemiLattice (M.Map k v) where
    bottom = M.empty

--
-- IntMaps
--

instance JoinSemiLattice v => JoinSemiLattice (IM.IntMap v) where
    (\/) = IM.unionWith (\/)

instance JoinSemiLattice v => BoundedJoinSemiLattice (IM.IntMap v) where
    bottom = IM.empty

instance MeetSemiLattice v => MeetSemiLattice (IM.IntMap v) where
    (/\) = IM.intersectionWith (/\)

instance Lattice v => Lattice (IM.IntMap v)

--
-- Functions
--

instance JoinSemiLattice v => JoinSemiLattice (k -> v) where
    f \/ g = \x -> f x \/ g x

instance MeetSemiLattice v => MeetSemiLattice (k -> v) where
    f /\ g = \x -> f x /\ g x

instance Lattice v => Lattice (k -> v) where

instance BoundedJoinSemiLattice v => BoundedJoinSemiLattice (k -> v) where
    bottom = const bottom

instance BoundedMeetSemiLattice v => BoundedMeetSemiLattice (k -> v) where
    top = const top

instance BoundedLattice v => BoundedLattice (k -> v) where

-- Unit
instance JoinSemiLattice () where
  _ \/ _ = ()

instance BoundedJoinSemiLattice () where
  bottom = ()

instance MeetSemiLattice () where
  _ /\ _ = ()

instance BoundedMeetSemiLattice () where
  top = ()

instance Lattice () where
instance BoundedLattice () where

--
-- Tuples
--

instance (JoinSemiLattice a, JoinSemiLattice b) => JoinSemiLattice (a, b) where
    (x1, y1) \/ (x2, y2) = (x1 \/ x2, y1 \/ y2)

instance (MeetSemiLattice a, MeetSemiLattice b) => MeetSemiLattice (a, b) where
    (x1, y1) /\ (x2, y2) = (x1 /\ x2, y1 /\ y2)

instance (Lattice a, Lattice b) => Lattice (a, b) where

instance (BoundedJoinSemiLattice a, BoundedJoinSemiLattice b) => BoundedJoinSemiLattice (a, b) where
    bottom = (bottom, bottom)

instance (BoundedMeetSemiLattice a, BoundedMeetSemiLattice b) => BoundedMeetSemiLattice (a, b) where
    top = (top, top)

instance (BoundedLattice a, BoundedLattice b) => BoundedLattice (a, b) where

--
-- Bools
--

instance JoinSemiLattice Bool where
    (\/) = (||)

instance MeetSemiLattice Bool where
    (/\) = (&&)

instance Lattice Bool where

instance BoundedJoinSemiLattice Bool where
    bottom = False

instance BoundedMeetSemiLattice Bool where
    top = True

instance BoundedLattice Bool where

--- Monoids

-- | Monoid wrapper for JoinSemiLattice
newtype Join a = Join { getJoin :: a }
  deriving (Eq, Ord, Read, Show, Bounded, Typeable, Data, Generic)

instance JoinSemiLattice a => Semigroup (Join a) where
  Join a <> Join b = Join (a \/ b)

instance BoundedJoinSemiLattice a => Monoid (Join a) where
  mempty = Join bottom
  Join a `mappend` Join b = Join (a \/ b)

instance Functor Join where
  fmap f (Join x) = Join (f x)

instance Applicative Join where
  pure = Join
  Join f <*> Join x = Join (f x)
  _ *> x = x

instance Monad Join where
  return = pure
  Join m >>= f = f m
  (>>) = (*>)

instance MonadZip Join where
  mzip (Join x) (Join y) = Join (x, y)

-- | Monoid wrapper for MeetSemiLattice
newtype Meet a = Meet { getMeet :: a }
  deriving (Eq, Ord, Read, Show, Bounded, Typeable, Data, Generic)

instance MeetSemiLattice a => Semigroup (Meet a) where
  Meet a <> Meet b = Meet (a /\ b)

instance BoundedMeetSemiLattice a => Monoid (Meet a) where
  mempty = Meet top
  Meet a `mappend` Meet b = Meet (a /\ b)

instance Functor Meet where
  fmap f (Meet x) = Meet (f x)

instance Applicative Meet where
  pure = Meet
  Meet f <*> Meet x = Meet (f x)
  _ *> x = x

instance Monad Meet where
  return = pure
  Meet m >>= f = f m
  (>>) = (*>)

instance MonadZip Meet where
  mzip (Meet x) (Meet y) = Meet (x, y)

-- All
instance JoinSemiLattice All where
  All a \/ All b = All $ a \/ b

instance BoundedJoinSemiLattice All where
  bottom = All False

instance MeetSemiLattice All where
  All a /\ All b = All $ a /\ b

instance BoundedMeetSemiLattice All where
  top = All True

instance Lattice All where
instance BoundedLattice All where

-- Any
instance JoinSemiLattice Any where
  Any a \/ Any b = Any $ a \/ b

instance BoundedJoinSemiLattice Any where
  bottom = Any False

instance MeetSemiLattice Any where
  Any a /\ Any b = Any $ a /\ b

instance BoundedMeetSemiLattice Any where
  top = Any True

instance Lattice Any where
instance BoundedLattice Any where

-- Endo
instance JoinSemiLattice a => JoinSemiLattice (Endo a) where
  Endo a \/ Endo b = Endo $ a \/ b

instance BoundedJoinSemiLattice a => BoundedJoinSemiLattice (Endo a) where
  bottom = Endo bottom

instance MeetSemiLattice a => MeetSemiLattice (Endo a) where
  Endo a /\ Endo b = Endo $ a /\ b

instance BoundedMeetSemiLattice a => BoundedMeetSemiLattice (Endo a) where
  top = Endo top

instance Lattice a => Lattice (Endo a) where
instance BoundedLattice a => BoundedLattice (Endo a) where

-- Proxy
instance JoinSemiLattice (Proxy a) where
  _ \/ _ = Proxy

instance BoundedJoinSemiLattice (Proxy a) where
  bottom = Proxy

instance MeetSemiLattice (Proxy a) where
  _ /\ _ = Proxy

instance BoundedMeetSemiLattice (Proxy a) where
  top = Proxy

instance Lattice (Proxy a) where
instance BoundedLattice (Proxy a) where

#if MIN_VERSION_base(4,8,0)
-- Identity
instance JoinSemiLattice a => JoinSemiLattice (Identity a) where
  Identity a \/ Identity b = Identity (a \/ b)

instance BoundedJoinSemiLattice a => BoundedJoinSemiLattice (Identity a) where
  bottom = Identity bottom

instance MeetSemiLattice a => MeetSemiLattice (Identity a) where
  Identity a /\ Identity b = Identity (a /\ b)

instance BoundedMeetSemiLattice a => BoundedMeetSemiLattice (Identity a) where
  top = Identity top

instance Lattice a => Lattice (Identity a) where
instance BoundedLattice a => BoundedLattice (Identity a) where
#endif

-- Const
instance JoinSemiLattice a => JoinSemiLattice (Const a b) where
  Const a \/ Const b = Const (a \/ b)

instance BoundedJoinSemiLattice a => BoundedJoinSemiLattice (Const a b) where
  bottom = Const bottom

instance MeetSemiLattice a => MeetSemiLattice (Const a b) where
  Const a /\ Const b = Const (a /\ b)

instance BoundedMeetSemiLattice a => BoundedMeetSemiLattice (Const a b) where
  top = Const top

instance Lattice a => Lattice (Const a b) where
instance BoundedLattice a => BoundedLattice (Const a b) where

-- Void
instance JoinSemiLattice Void where
  a \/ _ = a

instance MeetSemiLattice Void where
  a /\ _ = a

instance Lattice Void where

-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Assumes that the function is monotone and does not check if that is correct.
{-# INLINE unsafeLfp #-}
unsafeLfp :: (Eq a, BoundedJoinSemiLattice a) => (a -> a) -> a
unsafeLfp = PO.unsafeLfpFrom bottom

-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Forces the function to be monotone.
{-# INLINE lfp #-}
lfp :: (Eq a, BoundedJoinSemiLattice a) => (a -> a) -> a
lfp = lfpFrom bottom

-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Forces the function to be monotone.
{-# INLINE lfpFrom #-}
lfpFrom :: (Eq a, BoundedJoinSemiLattice a) => a -> (a -> a) -> a
lfpFrom init_x f = PO.unsafeLfpFrom init_x (\x -> f x \/ x)


-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Assumes that the function is antinone and does not check if that is correct.
{-# INLINE unsafeGfp #-}
unsafeGfp :: (Eq a, BoundedMeetSemiLattice a) => (a -> a) -> a
unsafeGfp = PO.unsafeGfpFrom top

-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Forces the function to be antinone.
{-# INLINE gfp #-}
gfp :: (Eq a, BoundedMeetSemiLattice a) => (a -> a) -> a
gfp = gfpFrom top

-- | Implementation of Kleene fixed-point theorem <http://en.wikipedia.org/wiki/Kleene_fixed-point_theorem>.
-- Forces the function to be antinone.
{-# INLINE gfpFrom #-}
gfpFrom :: (Eq a, BoundedMeetSemiLattice a) => a -> (a -> a) -> a
gfpFrom init_x f = PO.unsafeGfpFrom init_x (\x -> f x /\ x)
