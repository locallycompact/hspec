{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ConstraintKinds #-}

module Test.Hspec.Core.Tree (
-- RE-EXPORTED from Test.Hspec.Core.Spec
  SpecTree
, Tree (..)
, Item (..)
, specGroup
, specItem
, bimapTree
, bimapForest
, filterTree
, filterForest
, filterTreeWithLabels
, filterForestWithLabels
, pruneTree -- unused
, pruneForest -- unused
, location
-- END RE-EXPORTED from Test.Hspec.Core.Spec
, callSite
) where

import           Prelude ()
import           Test.Hspec.Core.Compat

import           Data.CallStack (SrcLoc(..))
import qualified Data.CallStack as CallStack

import           Test.Hspec.Core.Example

-- | Internal tree data structure
data Tree c a =
    Node String [Tree c a]
  | NodeWithCleanup (Maybe (String, Location)) c [Tree c a]
  | Leaf a
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | A tree is used to represent a spec internally.  The tree is parameterized
-- over the type of cleanup actions and the type of the actual spec items.
type SpecTree a = Tree (IO ()) (Item a)

bimapForest :: (a -> b) -> (c -> d) -> [Tree a c] -> [Tree b d]
bimapForest g f = map (bimapTree g f)

bimapTree :: (a -> b) -> (c -> d) -> Tree a c -> Tree b d
bimapTree g f = go
  where
    go spec = case spec of
      Node d xs -> Node d (map go xs)
      NodeWithCleanup loc action xs -> NodeWithCleanup loc (g action) (map go xs)
      Leaf item -> Leaf (f item)

filterTree :: (a -> Bool) -> Tree c a -> Maybe (Tree c a)
filterTree = filterTreeWithLabels . const

filterForest :: (a -> Bool) -> [Tree c a] -> [Tree c a]
filterForest = filterForestWithLabels . const

filterTreeWithLabels :: ([String] -> a -> Bool) -> Tree c a -> Maybe (Tree c a)
filterTreeWithLabels = filterTree_ []

filterForestWithLabels :: ([String] -> a -> Bool) -> [Tree c a] -> [Tree c a]
filterForestWithLabels = filterForest_ []

filterForest_ :: [String] -> ([String] -> a -> Bool) -> [Tree c a] -> [Tree c a]
filterForest_ groups = mapMaybe . filterTree_ groups

filterTree_ :: [String] -> ([String] -> a -> Bool) -> Tree c a -> Maybe (Tree c a)
filterTree_ groups p tree = case tree of
  Node group xs -> Just $ Node group $ filterForest_ (groups ++ [group]) p xs
  NodeWithCleanup loc action xs -> Just $ NodeWithCleanup loc action $ filterForest_ groups p xs
  Leaf item -> Leaf <$> guarded (p groups) item

pruneForest :: [Tree c a] -> [Tree c a]
pruneForest = mapMaybe pruneTree

pruneTree :: Tree c a -> Maybe (Tree c a)
pruneTree node = case node of
  Node group xs -> Node group <$> prune xs
  NodeWithCleanup loc action xs -> NodeWithCleanup loc action <$> prune xs
  Leaf{} -> Just node
  where
    prune = guarded (not . null) . pruneForest

-- |
-- @Item@ is used to represent spec items internally.  A spec item consists of:
--
-- * a textual description of a desired behavior
-- * an example for that behavior
-- * additional meta information
--
-- Everything that is an instance of the `Example` type class can be used as an
-- example, including QuickCheck properties, Hspec expectations and HUnit
-- assertions.
data Item a = Item {

  -- | Textual description of behavior
  itemRequirement :: String

  -- | Source location of the spec item
, itemLocation :: Maybe Location

  -- | A flag that indicates whether it is safe to evaluate this spec item in
  -- parallel with other spec items
, itemIsParallelizable :: Maybe Bool

  -- | A flag that indicates whether this spec item is focused.
, itemIsFocused :: Bool

  -- | Example for behavior
, itemExample :: Params -> (ActionWith a -> IO ()) -> ProgressCallback -> IO Result
}

-- | The @specGroup@ function combines a list of specs into a larger spec.
specGroup :: HasCallStack => String -> [SpecTree a] -> SpecTree a
specGroup s = Node msg
  where
    msg :: HasCallStack => String
    msg
      | null s = fromMaybe "(no description given)" defaultDescription
      | otherwise = s

-- | The @specItem@ function creates a spec item.
specItem :: (HasCallStack, Example e) => String -> e -> SpecTree (Arg e)
specItem s e = Leaf Item {
    itemRequirement = requirement
  , itemLocation = location
  , itemIsParallelizable = Nothing
  , itemIsFocused = False
  , itemExample = safeEvaluateExample e
  }
  where
    requirement :: HasCallStack => String
    requirement
      | null s = fromMaybe "(unspecified behavior)" defaultDescription
      | otherwise = s

location :: HasCallStack => Maybe Location
location = snd <$> callSite

callSite :: HasCallStack => Maybe (String, Location)
callSite = fmap toLocation <$> CallStack.callSite

defaultDescription :: HasCallStack => Maybe String
defaultDescription = case CallStack.callSite of
  Just (_, loc) -> Just (srcLocModule loc ++ "[" ++ show (srcLocStartLine loc) ++ ":" ++ show (srcLocStartCol loc) ++ "]")
  Nothing -> Nothing
