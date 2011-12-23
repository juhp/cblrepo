{-
 - Copyright 2011 Per Magnus Therning
 -
 - Licensed under the Apache License, Version 2.0 (the "License");
 - you may not use this file except in compliance with the License.
 - You may obtain a copy of the License at
 -
 -     http://www.apache.org/licenses/LICENSE-2.0
 -
 - Unless required by applicable law or agreed to in writing, software
 - distributed under the License is distributed on an "AS IS" BASIS,
 - WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 - See the License for the specific language governing permissions and
 - limitations under the License.
 -}

module Add where

import Debug.Trace

-- {{{1 imports
-- {{{2 local
import PkgDB
import Util.Misc

-- {{{2 system
import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Data.Either
import Data.List
import Data.Maybe
import Data.Version
import Distribution.Compiler
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.System
import Distribution.Text
import Distribution.Verbosity
import Distribution.Version
import System.Directory
import System.FilePath
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Distribution.Package as P
import System.Posix.Files
import System.Unix.Directory
import System.Process
import System.Exit
import System.IO

-- {{{1 types
data PkgType
    = GhcType String Version
    | DistroType String Version String
    | RepoType GenericPackageDescription
    deriving (Eq, Show)

-- {{{1 add
add :: Command ()
add = do
    dbFn <- cfgGet dbFile
    db <- liftIO $ readDb dbFn
    pd <- cfgGet patchDir
    dr <- cfgGet dryRun
    --
    ghcPkgs <- cfgGet cmdAddGhcPkgs
    distroPkgs <- cfgGet cmdAddDistroPkgs
    genUrlPkgs <- cfgGet cmdAddUrlCbls >>= mapM (\ c -> runErrorT $ withTempDirErrT "/tmp/cblrepo." (\ d -> readCabalFromUrl pd c d))
    genFilePkgs <- cfgGet cmdAddFileCbls >>= mapM (\ c -> runErrorT $ withTempDirErrT "/tmp/cblrepo." (\ d -> readCabalFromFile pd c d))
    genIdxPkgs <- cfgGet cmdAddCbls >>= mapM (\ c -> runErrorT $ withTempDirErrT "/tmp/cblrepo." (\ d -> readCabalFromIdx pd c d))
    pkgs <- exitOnErrors $ argsToPkgType ghcPkgs distroPkgs (genUrlPkgs ++ genFilePkgs ++ genIdxPkgs)
    --
    let pkgNames = map getName pkgs
    let tmpDb = foldl delPkg db pkgNames
    case addPkgs tmpDb pkgs of
        Left (unsatisfiables, breaksOthers) -> liftIO (mapM_ printUnSat unsatisfiables >> mapM_ printBrksOth breaksOthers)
        Right newDb -> liftIO $ unless dr $ saveDb newDb dbFn

argsToPkgType ghcPkgs distroPkgs repoPkgs = let
        toGhcType (n, v) = maybe
            (Left $ "Not a valid version given for " ++ n ++ " (" ++ v ++ ")")
            (Right . GhcType n)
            (simpleParse v :: Maybe Version)
        toDistroType (n, v, r) = maybe
            (Left $ "Not a valid version given for " ++ n ++ " (" ++ v ++ ")")
            (\ v' -> Right $ DistroType n v' r)
            (simpleParse v :: Maybe Version)
        toRepoType = either Left (Right . RepoType)
    in map toGhcType ghcPkgs ++ map toDistroType distroPkgs ++ map toRepoType repoPkgs

getName (GhcType n _) = n
getName (DistroType n _ _) = n
getName (RepoType gpd) = (\ (P.PackageName n) -> n) $ P.pkgName $ package $ packageDescription gpd

-- {{{1 addPkgs
addPkgs db pkgs = let
        (succs, fails) = partition (canBeAdded db) pkgs
        newDb = foldl addPkg2 db (map (pkgTypeToCblPkg db) succs)
        unsatisfieds = mapMaybe (finalizeToUnsatisfiableDeps db) fails
        breaksOthers = mapMaybe (findBreaking db) fails
    in case (succs, fails) of
        (_, []) -> Right newDb
        ([], _) -> Left (unsatisfieds, breaksOthers)
        (_, _) -> addPkgs newDb fails

canBeAdded db (GhcType n v) = null $ checkDependants db n v
canBeAdded db (DistroType n v _) = null $ checkDependants db n v
canBeAdded db (RepoType gpd) = let
        finable = either (const False) (const True) (finalizePkg db gpd)
        n = ((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) gpd
        v = P.pkgVersion $ package $ packageDescription gpd
        depsOK = null $ checkDependants db n v
    in finable && depsOK

pkgTypeToCblPkg _ (GhcType n v) = createGhcPkg n v
pkgTypeToCblPkg _ (DistroType n v r) = createDistroPkg n v r
pkgTypeToCblPkg db (RepoType gpd) = fromJust $ case finalizePkg db gpd of
    Right (pd, _) -> Just $ createCblPkg pd
    Left _ -> Nothing

finalizeToUnsatisfiableDeps db (RepoType gpd) = case finalizePkg db gpd of
    Left ds -> Just $ (((\ (P.PackageName n) -> n ) . P.pkgName . package . packageDescription) gpd, ds)
    _ -> Nothing
finalizeToUnsatisfiableDeps _ _ = Nothing

findBreaking db (GhcType n v) = let
        d = checkDependants db n v
    in if null d
        then Nothing
        else Just ((n, v), d)
findBreaking db (DistroType n v _) = let
        d = checkDependants db n v
    in if null d
        then Nothing
        else Just ((n, v), d)
findBreaking db (RepoType gpd) = let
        n = (\ (P.PackageName n) -> n) $ P.pkgName $ package $ packageDescription gpd
        v = P.pkgVersion $ package $ packageDescription gpd
        d = checkDependants db n v
    in if null d
        then Nothing
        else Just ((n, v), d)
