{-# LANGUAGE CPP         #-}
{-# LANGUAGE Trustworthy #-}

-- | This module extends "System.Path" (which is re-exported for
-- convenience) with thin wrappers around common IO functions
-- and is intended to replace imports of "System.FilePath",
--
-- To facilitate importing this module unqualified we also re-export
-- some definitions from "System.IO" (importing both would likely lead
-- to name clashes).
module System.Path.IO
  (
    -- * Wrappers
    -- ** Wrappers around "System.IO"
    withFile
  , openTempFile'
    -- ** Wrappers around "Data.ByteString"
  , readLazyByteString
  , readStrictByteString
  , writeLazyByteString
  , writeStrictByteString
    -- ** Wrappers around "System.Directory"
  , copyFile
  , createDirectory
  , createDirectoryIfMissing
  , removeDirectory
  , doesFileExist
  , doesDirectoryExist
  , getModificationTime
  , removeFile
  , getTemporaryDirectory
  , getDirectoryContents
  , getRecursiveContents
  , renameFile
  , getCurrentDirectory

    -- * Re-exports
    -- ** Re-exported "System.Path" module
  , module System.Path
    -- ** "System.IO" re-exports
  , IOMode(..)
  , BufferMode(..)
  , Handle
  , SeekMode(..)
  , IO.hSetBuffering
  , IO.hClose
  , IO.hFileSize
  , IO.hSeek
  ) where

import           System.Path

#if !MIN_VERSION_base(4,8,0)
import           Control.Applicative   ((<$>))
#endif
import           Control.Monad
import           Data.Time             (UTCTime)
import           System.IO             (BufferMode (..), Handle, IOMode (..),
                                        SeekMode (..))
import           System.IO.Unsafe      (unsafeInterleaveIO)
#if !MIN_VERSION_directory(1,2,0)
import           Data.Time.Clock       (picosecondsToDiffTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           System.Time           (ClockTime (TOD))
#endif
import qualified Data.ByteString       as BS
import qualified Data.ByteString.Lazy  as BS.L
import qualified System.Directory      as Dir
import qualified System.IO             as IO

{-------------------------------------------------------------------------------
  Wrappers around System.IO
-------------------------------------------------------------------------------}

-- | Wrapper around 'withFile'
withFile :: FsRoot root => Path root -> IOMode -> (Handle -> IO r) -> IO r
withFile path mode callback = do
    filePath <- toAbsoluteFilePath path
    IO.withFile filePath mode callback

-- | Wrapper around 'openBinaryTempFileWithDefaultPermissions'
--
-- NOTE: The caller is responsible for cleaning up the temporary file.
openTempFile' :: FsRoot root => Path root -> String -> IO (Path Absolute, Handle)
openTempFile' path template = do
    filePath <- toAbsoluteFilePath path
    (tempFilePath, h) <- IO.openBinaryTempFileWithDefaultPermissions filePath template
    return (fromAbsoluteFilePath tempFilePath, h)

{-------------------------------------------------------------------------------
  Wrappers around Data.ByteString.*
-------------------------------------------------------------------------------}

readLazyByteString :: FsRoot root => Path root -> IO BS.L.ByteString
readLazyByteString path = do
    filePath <- toAbsoluteFilePath path
    BS.L.readFile filePath

readStrictByteString :: FsRoot root => Path root -> IO BS.ByteString
readStrictByteString path = do
    filePath <- toAbsoluteFilePath path
    BS.readFile filePath

writeLazyByteString :: FsRoot root => Path root -> BS.L.ByteString -> IO ()
writeLazyByteString path bs = do
    filePath <- toAbsoluteFilePath path
    BS.L.writeFile filePath bs

writeStrictByteString :: FsRoot root => Path root -> BS.ByteString -> IO ()
writeStrictByteString path bs = do
    filePath <- toAbsoluteFilePath path
    BS.writeFile filePath bs

{-------------------------------------------------------------------------------
  Wrappers around System.Directory
-------------------------------------------------------------------------------}

copyFile :: (FsRoot root, FsRoot root') => Path root -> Path root' -> IO ()
copyFile src dst = do
    src' <- toAbsoluteFilePath src
    dst' <- toAbsoluteFilePath dst
    Dir.copyFile src' dst'

createDirectory :: FsRoot root => Path root -> IO ()
createDirectory path = Dir.createDirectory =<< toAbsoluteFilePath path

createDirectoryIfMissing :: FsRoot root => Bool -> Path root -> IO ()
createDirectoryIfMissing createParents path = do
    filePath <- toAbsoluteFilePath path
    Dir.createDirectoryIfMissing createParents filePath

removeDirectory :: FsRoot root => Path root -> IO ()
removeDirectory path = Dir.removeDirectory =<< toAbsoluteFilePath path

doesFileExist :: FsRoot root => Path root -> IO Bool
doesFileExist path = do
    filePath <- toAbsoluteFilePath path
    Dir.doesFileExist filePath

doesDirectoryExist :: FsRoot root => Path root -> IO Bool
doesDirectoryExist path = do
    filePath <- toAbsoluteFilePath path
    Dir.doesDirectoryExist filePath

getModificationTime :: FsRoot root => Path root -> IO UTCTime
getModificationTime path = do
    filePath <- toAbsoluteFilePath path
    toUTC <$> Dir.getModificationTime filePath
  where
#if MIN_VERSION_directory(1,2,0)
    toUTC :: UTCTime -> UTCTime
    toUTC = id
#else
    toUTC :: ClockTime -> UTCTime
    toUTC (TOD secs psecs) = posixSecondsToUTCTime $ realToFrac $ picosecondsToDiffTime (psecs + secs*1000000000000)
#endif

removeFile :: FsRoot root => Path root -> IO ()
removeFile path = do
    filePath <- toAbsoluteFilePath path
    Dir.removeFile filePath

getTemporaryDirectory :: IO (Path Absolute)
getTemporaryDirectory = fromAbsoluteFilePath <$> Dir.getTemporaryDirectory

-- | Return the immediate children of a directory
--
-- Filters out @"."@ and @".."@.
getDirectoryContents :: FsRoot root => Path root -> IO [Path Unrooted]
getDirectoryContents path = do
    filePath <- toAbsoluteFilePath path
    fragments <$> Dir.getDirectoryContents filePath
  where
    fragments :: [String] -> [Path Unrooted]
    fragments = map fragment . filter (not . skip)

    skip :: String -> Bool
    skip "."  = True
    skip ".." = True
    skip _    = False

-- | Recursive traverse a directory structure
--
-- Returns a set of paths relative to the directory specified. The list is
-- lazily constructed, so that directories are only read when required.
-- (This is also essential to ensure that this function does not build the
-- entire result in memory before returning, potentially running out of heap.)
getRecursiveContents :: FsRoot root => Path root -> IO [Path Unrooted]
getRecursiveContents root = go emptyPath
  where
    go :: Path Unrooted -> IO [Path Unrooted]
    go subdir = unsafeInterleaveIO $ do
      entries <- getDirectoryContents (root </> subdir)
      liftM concat $ forM entries $ \entry -> do
        let path = subdir </> entry
        isDirectory <- doesDirectoryExist (root </> path)
        if isDirectory then go path
                       else return [path]

    emptyPath :: Path Unrooted
    emptyPath = joinFragments []

renameFile :: (FsRoot root, FsRoot root')
           => Path root  -- ^ Old
           -> Path root' -- ^ New
           -> IO ()
renameFile old new = do
    old' <- toAbsoluteFilePath old
    new' <- toAbsoluteFilePath new
    Dir.renameFile old' new'

getCurrentDirectory :: IO (Path Absolute)
getCurrentDirectory = do
    cwd <- Dir.getCurrentDirectory
    makeAbsolute $ fromFilePath cwd

