{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RoleAnnotations #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -fno-cse -fno-full-laziness #-}

module Data.Discrimination.Grouping
  ( Group(..)
  , Grouping(..)
  , Grouping1(..)
  -- * Combinators
  , nub, nubWith
  , group, groupWith
  , groupingEq
  -- * Internals
  , groupingBag
  , groupingSet
  , groupingShort
  , groupingNat
  ) where

import Control.Arrow
import Control.Monad
import Control.Monad.ST.Class
import Data.Bits
import Data.Complex
import Data.Discrimination.Internal
import Data.Foldable hiding (concat)
import Data.Functor
import Data.Functor.Compose
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Functor.Contravariant.Generic
import Data.Int
import Data.Monoid hiding (Any)
import Data.Promise
import Data.Proxy
import Data.Ratio
import Data.Typeable
import qualified Data.Vector.Mutable as UM
import Data.Void
import Data.Word
import Prelude hiding (read, concat)

-- | Discriminator

-- TODO: use [(a,b)] -> [NonEmpty b] to better indicate safety?
newtype Group a = Group { runGroup :: forall b. [(a,b)] -> [[b]] }
  deriving Typeable

#ifndef HLINT
type role Group representational
#endif

instance Contravariant Group where
  contramap f (Group g) = Group $ g . map (first f)

instance Divisible Group where
  conquer = Group $ return . fmap snd
  divide k (Group l) (Group r) = Group $ \xs ->
    l [ (b, (c, d)) | (a,d) <- xs, let (b, c) = k a] >>= r

instance Decidable Group where
  lose k = Group $ fmap (absurd.k.fst)
  choose f (Group l) (Group r) = Group $ \xs -> let
      ys = zipWith (\n (a,d) -> (f a, (n, d))) [0..] xs
    in l [ (k,p) | (Left k, p) <- ys ] `mix`
       r [ (k,p) | (Right k, p) <- ys ]

mix :: [[(Int,b)]] -> [[(Int,b)]] -> [[b]]
mix [] bs = fmap snd <$> bs
mix as [] = fmap snd <$> as
mix asss@(((n,a):as):ass) bsss@(((m,b):bs):bss)
  | n < m     = (a:fmap snd as) : mix ass bsss
  | otherwise = (b:fmap snd bs) : mix asss bss
mix _ _ = error "bad discriminator"

instance Monoid (Group a) where
  mempty = conquer
  mappend (Group l) (Group r) = Group $ \xs -> l [ (fst x, x) | x <- xs ] >>= r

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

-- | Perform productive stable unordered discrimination by bucket.
groupingNat :: Int -> Group Int
groupingNat = \ n -> Group $ \xs -> runLazy (\r -> liftST (UM.replicate n Nothing) >>= go xs r) [] where
  go :: [(Int,b)] -> Promise s [[b]] -> UM.MVector s (Maybe (Promise s [b])) -> Lazy s ()
  go [] _ _ = return ()
  go ((k,v):kvs) r t = liftST (UM.read t k) >>= \vs -> case vs of
    Just p -> do
      q <- promise []
      p != v : demand q
      liftST $ UM.write t k $ Just q
      go kvs r t
    Nothing -> do
      q <- promise []
      liftST $ UM.write t k $ Just q
      r' <- promise []
      r != (v : demand q) : demand r'
      go kvs r' t
  
-- | Shared bucket set for small integers
groupingShort :: Group Int
groupingShort = groupingNat 65536
{-# NOINLINE groupingShort #-}

--------------------------------------------------------------------------------
-- * Unordered Discrimination (for partitioning)
--------------------------------------------------------------------------------

-- | 'Eq' equipped with a compatible stable unordered discriminator.
class Grouping a where
  -- | For every surjection @f@,
  --
  -- @
  -- 'contramap' f 'grouping' ≡ 'grouping'
  -- @

  grouping :: Group a
#ifndef HLINT
  default grouping :: Deciding Grouping a => Group a
  grouping = deciding (Proxy :: Proxy Grouping) grouping
#endif

instance Grouping Void where
  grouping = lose id

instance Grouping Word8 where
  grouping = contramap fromIntegral groupingShort

instance Grouping Word16 where
  grouping = contramap fromIntegral groupingShort

instance Grouping Word32 where
  grouping = Group (runs <=< runGroup groupingShort . join . runGroup groupingShort . map radices) where
    radices (x,b) = (fromIntegral x .&. 0xffff, (fromIntegral (unsafeShiftR x 16), (x,b)))

instance Grouping Word64 where
  grouping = Group (runs <=< runGroup groupingShort . join . runGroup groupingShort . join
                          . runGroup groupingShort . join . runGroup groupingShort . map radices)
    where
      radices (x,b) = (fromIntegral x .&. 0xffff, (fromIntegral (unsafeShiftR x 16) .&. 0xffff
                    , (fromIntegral (unsafeShiftR x 32) .&. 0xffff, (fromIntegral (unsafeShiftR x 48)
                    , (x,b)))))


instance Grouping Word where
  grouping
    | (maxBound :: Word) == 4294967295 = contramap (fromIntegral :: Word -> Word32) grouping
    | otherwise                        = contramap (fromIntegral :: Word -> Word64) grouping

instance Grouping Int8 where
  grouping = contramap (\x -> fromIntegral x + 128) groupingShort

instance Grouping Int16 where
  grouping = contramap (\x -> fromIntegral x + 32768) groupingShort

instance Grouping Int32 where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word32) grouping

instance Grouping Int64 where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word64) grouping

instance Grouping Int where
  grouping = contramap (\x -> fromIntegral (x - minBound) :: Word) grouping

instance Grouping Bool
instance (Grouping a, Grouping b) => Grouping (a, b)
instance (Grouping a, Grouping b, Grouping c) => Grouping (a, b, c)
instance (Grouping a, Grouping b, Grouping c, Grouping d) => Grouping (a, b, c, d)
instance Grouping a => Grouping [a]
instance Grouping a => Grouping (Maybe a)
instance (Grouping a, Grouping b) => Grouping (Either a b)
instance Grouping a => Grouping (Complex a) where
  grouping = divide (\(a :+ b) -> (a, b)) grouping grouping
instance (Grouping a, Integral a) => Grouping (Ratio a) where
  grouping = divide (\r -> (numerator r, denominator r)) grouping grouping
instance (Grouping1 f, Grouping1 g, Grouping a) => Grouping (Compose f g a) where
  grouping = getCompose `contramap` grouping1 (grouping1 grouping)

class Grouping1 f where
  grouping1 :: Group a -> Group (f a)
#ifndef HLINT
  default grouping1 :: Deciding1 Grouping f => Group a -> Group (f a)
  grouping1 = deciding1 (Proxy :: Proxy Grouping) grouping
#endif

instance Grouping1 []
instance Grouping1 Maybe
instance Grouping a => Grouping1 (Either a)
instance Grouping a => Grouping1 ((,) a)
instance (Grouping a, Grouping b) => Grouping1 ((,,) a b)
instance (Grouping a, Grouping b, Grouping c) => Grouping1 ((,,,) a b c)
instance (Grouping1 f, Grouping1 g) => Grouping1 (Compose f g) where
  grouping1 f = getCompose `contramap` grouping1 (grouping1 f)
instance Grouping1 Complex where
  grouping1 f = divide (\(a :+ b) -> (a, b)) f f

-- | Valid definition for @('==')@ in terms of 'Grouping'.
groupingEq :: Grouping a => a -> a -> Bool
groupingEq a b = case runGroup grouping [(a,()),(b,())] of
  _:_:_ -> False
  _ -> True
{-# INLINE groupingEq #-}

--------------------------------------------------------------------------------
-- * Combinators
--------------------------------------------------------------------------------

-- | /O(n)/. Similar to 'Data.List.group', except we do not require groups to be clustered.
--
-- This combinator still operates in linear time, at the expense of productivity.
--
-- The result equivalence classes are _not_ sorted, but the grouping is stable.
--
-- @
-- 'group' = 'groupWith' 'id'
-- @
group :: Grouping a => [a] -> [[a]]
group as = runGroup grouping [(a, a) | a <- as]

-- | /O(n)/. This is a replacement for 'GHC.Exts.groupWith' using discrimination.
--
-- The result equivalence classes are _not_ sorted, but the grouping is stable.
groupWith :: Grouping b => (a -> b) -> [a] -> [[a]]
groupWith f as = runGroup grouping [(f a, a) | a <- as]

-- | /O(n)/. This upgrades 'Data.List.nub' from @Data.List@ from /O(n^2)/ to /O(n)/ by using
-- unordered discrimination.
--
-- @
-- 'nub' = 'nubWith' 'id'
-- 'nub' as = 'head' 'Control.Applicative.<$>' 'group' as
-- @
nub :: Grouping a => [a] -> [a]
nub as = head <$> group as

-- | /O(n)/. 'nub' with a Schwartzian transform.
--
-- @
-- 'nubWith' f as = 'head' 'Control.Applicative.<$>' 'groupWith' f as
-- @
nubWith :: Grouping b => (a -> b) -> [a] -> [a]
nubWith f as = head <$> groupWith f as

--------------------------------------------------------------------------------
-- * Collections
--------------------------------------------------------------------------------

-- | Construct an stable unordered discriminator that partitions into equivalence classes based on the equivalence of keys as a multiset.
groupingBag :: Foldable f => Group k -> Group (f k)
groupingBag = groupingColl updateBag

-- | Construct an stable unordered discriminator that partitions into equivalence classes based on the equivalence of keys as a set.
groupingSet :: Foldable f => Group k -> Group (f k)
groupingSet = groupingColl updateSet

groupingColl :: Foldable f => ([Int] -> Int -> [Int]) -> Group k -> Group (f k)
groupingColl update r = Group $ \xss -> let
    (kss, vs)           = unzip xss
    elemKeyNumAssocs    = groupNum (toList <$> kss)
    keyNumBlocks        = runGroup r elemKeyNumAssocs
    keyNumElemNumAssocs = groupNum keyNumBlocks
    sigs                = bdiscNat (length kss) update keyNumElemNumAssocs
    yss                 = zip sigs vs
  in filter (not . null) $ grouping1 (groupingNat (length keyNumBlocks)) `runGroup` yss
