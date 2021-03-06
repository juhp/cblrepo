{-# LANGUAGE DeriveDataTypeable #-}
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

module Util.Misc where

import qualified PkgDB as DB

import Codec.Archive.Tar as Tar
import Codec.Compression.GZip as GZip
import Control.Concurrent
import Control.Monad
import Control.Monad.Error
import Control.Monad.Reader
import Data.Data
import Data.Either
import Data.List
import Data.Typeable
import Distribution.Compiler
import Distribution.Package
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import Distribution.System
import Distribution.Text
import Distribution.Verbosity
import Distribution.Version
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Posix.Files
import System.Process
import System.Unix.Directory
import qualified Control.Exception as CE
import qualified Data.ByteString.Lazy.Char8 as BS

-- {{{1 Dependency
depName (Dependency (PackageName n) _) = n
depVersionRange (Dependency _ vr) = vr

-- {{{ print functions
printUnSat (n, ds) = do
    putStrLn $ "Failed to satisfy the following dependencies for " ++ n ++ ":"
    mapM_ (putStrLn . ("  " ++) . display) ds

printBrksOth  ((n, v), brks) = do
    putStrLn $ "Adding " ++ n ++ " " ++ (display v) ++ " would break:"
    mapM_ (\ (bN, (Just bD)) -> putStrLn $ "  " ++ bN ++ " : " ++ (display bD)) brks

-- {{{1 program variables
progName = "cblrepo"
dbName = progName ++ ".db"

-- {{{1 command line argument type
data PkgType = GhcPkgT | DistroPkgT | RepoPkgT
    deriving (Show, Data, Typeable)

data Cmds
    = CmdAdd { appDir :: FilePath, dbFile :: FilePath, patchDir :: FilePath, dryRun :: Bool, pkgType :: PkgType, cbls :: [FilePath] }
    | BuildPkgs { appDir :: FilePath, dbFile :: FilePath, pkgs :: [String] }
    | BumpPkgs { appDir :: FilePath, dbFile :: FilePath, dryRun :: Bool, inclusive :: Bool, pkgs :: [String] }
    | Sync { appDir :: FilePath }
    | Versions { appDir :: FilePath, pkgs :: [String] }
    | ListPkgs { appDir :: FilePath, dbFile :: FilePath, listAll :: Bool }
    | Updates { appDir :: FilePath, dbFile :: FilePath }
    | Urls { appDir :: FilePath, pkgVers :: [(String, String)] }
    | PkgBuild { appDir :: FilePath, dbFile :: FilePath, patchDir :: FilePath, pkgs :: [String] }
    | ConvertDb { appDir :: FilePath, inDbFile :: FilePath, outDbFile :: FilePath }
    | RemovePkg { appDir :: FilePath, dbFile :: FilePath, dryRun :: Bool, pkgs :: [String] }
    deriving (Show, Data, Typeable)

defCmdAdd = CmdAdd "" "" "" True RepoPkgT []
defBuildPkgs =  BuildPkgs "" "" []
defBumpPkgs =  BumpPkgs "" "" False False []
defSync =  Sync ""
defVersions =  Versions "" []
defListPkgs =  ListPkgs "" "" False
defUpdates =  Updates "" ""
defUrls =  Urls "" []
defPkgBuild =  PkgBuild "" "" "" []
defConvertDb = ConvertDb "" "" ""
defRemovePkg = RemovePkg "" "" False []

cfgGet f = liftM f ask

-- {{{1 getFromURL
getFromURL url fn = do
    (ec, _, er) <- readProcessWithExitCode "curl" ["-f", "-o", fn, url] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ -> do
            hPutStrLn stderr ("Failed downloading " ++ url)
            hPutStrLn stderr er
            exitFailure

-- {{{1 applyPatchIfExist
applyPatch origFilename patchFilename = do
    (ec, _, err) <- liftIO $ readProcessWithExitCode "patch" [origFilename, patchFilename] ""
    case ec of
        ExitSuccess -> return ()
        ExitFailure _ ->
            throwError ("Failed patching " ++ origFilename ++ " with " ++ patchFilename)

applyPatchIfExist origFilename patchFilename =
    (liftIO $ fileExist patchFilename) >>= flip when (applyPatch origFilename patchFilename)

-- {{{1 package descriptions
-- {{{2 readCabal
data LocType = Url | Idx | File

-- | Read in a Cabal file.
readCabal :: FilePath -> String -> FilePath -> ErrorT String IO GenericPackageDescription
readCabal patchDir loc tmpDir = let
        locType
            | isInfixOf "://" loc = Url
            | ',' `elem` loc = Idx
            | otherwise = File

        copyCabal tmpDir loc = copyFile loc fn >> return fn
            where fn = tmpDir </> takeFileName loc

        downloadCabal tmpDir loc = getFromURL loc fn >> return fn
            where
                fn = tmpDir </> takeFileName loc

        extractCabal tmpDir loc = let
                (p, (_: v)) = span (/= ',') loc
                path = p </> v </> p ++ ".cabal"
                pkgStr = p ++ " " ++ v
                fn = tmpDir </> (p ++ ".cabal")

                esFindEntry p (Next e es) = if p == (entryPath e)
                    then Just e
                    else esFindEntry p es
                esFindEntry _ _ = Nothing

                eGetContent e = let
                        ec = entryContent e
                    in case ec of
                        NormalFile c _ -> Just $ BS.unpack c
                        _ -> Nothing

            in do
                fp <- liftIO $ getAppUserDataDirectory "cblrepo"
                es <- liftM (Tar.read . GZip.decompress)
                    (liftIO $ BS.readFile $ fp </> "00-index.tar.gz")
                e <- maybe (throwError $ "No entry for " ++ pkgStr)
                    return
                    (esFindEntry path es)
                cbl <- maybe (throwError $ "Failed to extract contents for " ++ pkgStr)
                    return
                    (eGetContent e)
                liftIO $ writeFile fn cbl
                return fn

        extractName fn = liftM name $ readPackageDescription silent fn
            where
                packageName (PackageName s) = s
                name = packageName . pkgName . package . packageDescription

    in do
        cblFn <- case locType of
            File -> liftIO $ copyCabal tmpDir loc
            Idx -> extractCabal tmpDir loc
            Url -> liftIO $ downloadCabal tmpDir loc
        pn <- liftIO $ extractName cblFn
        let patchFn = patchDir </> pn <.> "cabal"
        applyPatchIfExist cblFn patchFn
        liftIO $ readPackageDescription silent cblFn

-- {{{2 finalising
finalizePkg db = finalizePackageDescription
    [] -- no flags
    (checkAgainstDb db)
    (Platform X86_64 buildOS) -- platform
    (CompilerId GHC (Version [7,0,2] []))  -- compiler version
    [] -- no additional constraints

checkAgainstDb db dep = let
        dN = depName dep
        dVR = depVersionRange dep
    in case DB.lookupPkg db dN of
        Nothing -> False
        Just (_, p) -> withinRange (DB.version p) dVR

-- {{{1 allPatches
allPatches pn patchDir = let
        cblPatch = patchDir </> pn <.> "cabal"
        pkgPatch = patchDir </> pn <.> "pkgbuild"
        bldPatch = patchDir </> pn <.> "build"
    in do
        cE <- fileExist cblPatch
        pE <- fileExist pkgPatch
        bE <- fileExist bldPatch
        return (if cE then Just cblPatch else Nothing,
            if pE then Just pkgPatch else Nothing,
            if bE then Just bldPatch else Nothing)

-- {{{1 ErrorT
reWrapErrT (Left e) = throwError e
reWrapErrT (Right v) = return v

withTempDirErrT fp func = do
    r <- liftIO $ withTemporaryDirectory fp (\ p -> runErrorT $ func p)
    reWrapErrT r

exitOnErrors vs = let
        es = lefts vs
    in
        if (not $ null $ lefts vs)
            then liftIO $ mapM_ (hPutStrLn stderr) es >> exitFailure
            else return (rights vs)
