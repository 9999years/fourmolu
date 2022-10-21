{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

-- | Manipulations on import lists.
module Ormolu.Imports
  ( normalizeImports,
  )
where

import Data.Bifunctor
import Data.Char (isAlphaNum)
import Data.Foldable (toList)
import Data.Function (on)
import Data.List (foldl', nubBy, sortBy, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import GHC.Data.FastString
import GHC.Hs
import GHC.Hs.ImpExp as GHC
import GHC.Types.Name.Reader
import GHC.Types.PkgQual
import GHC.Types.SourceText
import GHC.Types.SrcLoc
import GHC.Unit.Module.Name
import GHC.Unit.Types
import Ormolu.Utils (groupBy', notImplemented, separatedByBlank, showOutputable)

-- | Sort, group and normalize imports.
--
-- Assumes input list is sorted by source location. Output list is not necessarily
-- sorted by source location, so this function should be called at most once on a
-- given input list.
normalizeImports :: Bool -> [LImportDecl GhcPs] -> [[LImportDecl GhcPs]]
normalizeImports preserveGroups =
  map
    ( fmap snd
        . M.toAscList
        . M.fromListWith combineImports
        . fmap (\x -> (importId x, g x))
    )
    . if preserveGroups
      then map toList . groupBy' (\x y -> not $ separatedByBlank getLocA x y)
      else pure
  where
    g :: LImportDecl GhcPs -> LImportDecl GhcPs
    g (L l ImportDecl {..}) =
      L
        l
        ImportDecl
          { ideclHiding = second (fmap normalizeLies) <$> ideclHiding,
            ..
          }

-- | Combine two import declarations. It should be assumed that 'ImportId's
-- are equal.
combineImports ::
  LImportDecl GhcPs ->
  LImportDecl GhcPs ->
  LImportDecl GhcPs
combineImports (L lx ImportDecl {..}) (L _ y) =
  L
    lx
    ImportDecl
      { ideclHiding = case (ideclHiding, GHC.ideclHiding y) of
          (Just (hiding, L l' xs), Just (_, L _ ys)) ->
            Just (hiding, (L l' (normalizeLies (xs ++ ys))))
          _ -> Nothing,
        ..
      }

-- | Import id, a collection of all things that justify having a separate
-- import entry. This is used for merging of imports. If two imports have
-- the same 'ImportId' they can be merged.
data ImportId = ImportId
  { importIsPrelude :: Bool,
    importIdName :: ModuleName,
    importPkgQual :: Maybe LexicalFastString,
    importSource :: IsBootInterface,
    importSafe :: Bool,
    importQualified :: Bool,
    importImplicit :: Bool,
    importAs :: Maybe ModuleName,
    importHiding :: Maybe Bool
  }
  deriving (Eq, Ord)

-- | Obtain an 'ImportId' for a given import.
importId :: LImportDecl GhcPs -> ImportId
importId (L _ ImportDecl {..}) =
  ImportId
    { importIsPrelude = isPrelude,
      importIdName = moduleName,
      importPkgQual = rawPkgQualToLFS ideclPkgQual,
      importSource = ideclSource,
      importSafe = ideclSafe,
      importQualified = case ideclQualified of
        QualifiedPre -> True
        QualifiedPost -> True
        NotQualified -> False,
      importImplicit = ideclImplicit,
      importAs = unLoc <$> ideclAs,
      importHiding = fst <$> ideclHiding
    }
  where
    isPrelude = moduleNameString moduleName == "Prelude"
    moduleName = unLoc ideclName
    rawPkgQualToLFS = \case
      RawPkgQual fs -> Just . LexicalFastString . sl_fs $ fs
      NoRawPkgQual -> Nothing

-- | Normalize a collection of import\/export items.
normalizeLies :: [LIE GhcPs] -> [LIE GhcPs]
normalizeLies = sortOn (getIewn . unLoc) . M.elems . foldl' combine M.empty
  where
    combine ::
      Map IEWrappedNameOrd (LIE GhcPs) ->
      LIE GhcPs ->
      Map IEWrappedNameOrd (LIE GhcPs)
    combine m (L new_l new) =
      let wname = getIewn new
          normalizeWNames =
            nubBy (\x y -> compareLIewn x y == EQ) . sortBy compareLIewn
          alter = \case
            Nothing -> Just . L new_l $
              case new of
                IEThingWith _ n wildcard g ->
                  IEThingWith EpAnnNotUsed n wildcard (normalizeWNames g)
                other -> other
            Just old ->
              let f = \case
                    IEVar _ n -> IEVar NoExtField n
                    IEThingAbs _ _ -> new
                    IEThingAll _ n -> IEThingAll EpAnnNotUsed n
                    IEThingWith _ n wildcard g ->
                      case new of
                        IEVar NoExtField _ ->
                          error "Ormolu.Imports broken presupposition"
                        IEThingAbs _ _ ->
                          IEThingWith EpAnnNotUsed n wildcard g
                        IEThingAll _ n' ->
                          IEThingAll EpAnnNotUsed n'
                        IEThingWith _ n' wildcard' g' ->
                          let combinedWildcard =
                                case (wildcard, wildcard') of
                                  (IEWildcard _, _) -> IEWildcard 0
                                  (_, IEWildcard _) -> IEWildcard 0
                                  _ -> NoIEWildcard
                           in IEThingWith
                                EpAnnNotUsed
                                n'
                                combinedWildcard
                                (normalizeWNames (g <> g'))
                        IEModuleContents _ _ -> notImplemented "IEModuleContents"
                        IEGroup NoExtField _ _ -> notImplemented "IEGroup"
                        IEDoc NoExtField _ -> notImplemented "IEDoc"
                        IEDocNamed NoExtField _ -> notImplemented "IEDocNamed"
                    IEModuleContents _ _ -> notImplemented "IEModuleContents"
                    IEGroup NoExtField _ _ -> notImplemented "IEGroup"
                    IEDoc NoExtField _ -> notImplemented "IEDoc"
                    IEDocNamed NoExtField _ -> notImplemented "IEDocNamed"
               in Just (f <$> old)
       in M.alter alter wname m

-- | A wrapper for @'IEWrappedName' 'RdrName'@ that allows us to define an
-- 'Ord' instance for it.
newtype IEWrappedNameOrd = IEWrappedNameOrd (IEWrappedName RdrName)
  deriving (Eq)

instance Ord IEWrappedNameOrd where
  compare (IEWrappedNameOrd x) (IEWrappedNameOrd y) = compareIewn x y

-- | Project @'IEWrappedName' 'RdrName'@ from @'IE' 'GhcPs'@.
getIewn :: IE GhcPs -> IEWrappedNameOrd
getIewn = \case
  IEVar NoExtField x -> IEWrappedNameOrd (unLoc x)
  IEThingAbs _ x -> IEWrappedNameOrd (unLoc x)
  IEThingAll _ x -> IEWrappedNameOrd (unLoc x)
  IEThingWith _ x _ _ -> IEWrappedNameOrd (unLoc x)
  IEModuleContents _ _ -> notImplemented "IEModuleContents"
  IEGroup NoExtField _ _ -> notImplemented "IEGroup"
  IEDoc NoExtField _ -> notImplemented "IEDoc"
  IEDocNamed NoExtField _ -> notImplemented "IEDocNamed"

-- | Like 'compareIewn' for located wrapped names.
compareLIewn :: LIEWrappedName RdrName -> LIEWrappedName RdrName -> Ordering
compareLIewn = compareIewn `on` unLoc

-- | Compare two @'IEWrapppedName' 'RdrName'@ things.
compareIewn :: IEWrappedName RdrName -> IEWrappedName RdrName -> Ordering
compareIewn (IEName x) (IEName y) = unLoc x `compareRdrName` unLoc y
compareIewn (IEName _) (IEPattern _ _) = LT
compareIewn (IEName _) (IEType _ _) = LT
compareIewn (IEPattern _ _) (IEName _) = GT
compareIewn (IEPattern _ x) (IEPattern _ y) = unLoc x `compareRdrName` unLoc y
compareIewn (IEPattern _ _) (IEType _ _) = LT
compareIewn (IEType _ _) (IEName _) = GT
compareIewn (IEType _ _) (IEPattern _ _) = GT
compareIewn (IEType _ x) (IEType _ y) = unLoc x `compareRdrName` unLoc y

compareRdrName :: RdrName -> RdrName -> Ordering
compareRdrName x y =
  case (getNameStr x, getNameStr y) of
    ([], []) -> EQ
    ((_ : _), []) -> GT
    ([], (_ : _)) -> LT
    ((x' : _), (y' : _)) ->
      case (isAlphaNum x', isAlphaNum y') of
        (False, False) -> x `compare` y
        (True, False) -> LT
        (False, True) -> GT
        (True, True) -> x `compare` y
  where
    getNameStr = showOutputable . rdrNameOcc
