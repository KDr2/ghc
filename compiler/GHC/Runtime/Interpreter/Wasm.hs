{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module GHC.Runtime.Interpreter.Wasm (spawnWasmInterp) where

import GHC.Prelude
import GHC.Runtime.Interpreter.Types

#if !defined(mingw32_HOST_OS)

import Control.Concurrent.MVar
import Data.Maybe
import GHC.Data.FastString
import qualified GHC.Data.ShortText as ST
import GHC.Platform
import GHC.Unit
import GHCi.Message
import System.Directory
import System.Environment.Blank
import System.IO
import qualified System.Posix.IO as Posix
import System.Process

#else

import GHC.Utils.Panic

#endif

spawnWasmInterp :: WasmInterpConfig -> IO (ExtInterpInstance ())

#if !defined(mingw32_HOST_OS)

-- See Note [The Wasm Dynamic Linker] for details
spawnWasmInterp WasmInterpConfig {..} = do
  let Just ghci_unit_id =
        lookupPackageName
          wasmInterpUnitState
          (PackageName $ fsLit "ghci")
      ghci_unit_info = unsafeLookupUnitId wasmInterpUnitState ghci_unit_id
      ghci_so_dirs = map ST.unpack $ unitLibraryDynDirs ghci_unit_info
      [ghci_lib_name] = map ST.unpack $ unitLibraries ghci_unit_info
      ghci_so_name = ghci_lib_name ++ wasmInterpHsSoSuffix
      ghci_so_file = platformHsSOName wasmInterpTargetPlatform ghci_so_name
  Just ghci_so_path <- findFile ghci_so_dirs ghci_so_file
  (rfd1, wfd1) <- Posix.createPipe
  (rfd2, wfd2) <- Posix.createPipe
  Posix.setFdOption rfd1 Posix.CloseOnExec True
  Posix.setFdOption wfd2 Posix.CloseOnExec True
  ghc_env <- getEnvironment
  let dyld_env =
        [("GHCI_BROWSER", "1") | wasmInterpBrowser]
        ++ [("GHCI_BROWSER_HOST", wasmInterpBrowserHost), ("GHCI_BROWSER_PORT", show wasmInterpBrowserPort)]
        ++ [("GHCI_BROWSER_REDIRECT_WASI_CONSOLE", "1") | wasmInterpBrowserRedirectWasiConsole]
        ++ [("GHCI_BROWSER_PUPPETEER_LAUNCH_OPTS", f) | f <- maybeToList wasmInterpBrowserPuppeteerLaunchOpts]
        ++ [("GHCI_BROWSER_PLAYWRIGHT_BROWSER_TYPE", f) | f <- maybeToList wasmInterpBrowserPlaywrightBrowserType]
        ++ [("GHCI_BROWSER_PLAYWRIGHT_LAUNCH_OPTS", f) | f <- maybeToList wasmInterpBrowserPlaywrightLaunchOpts]
        ++ ghc_env
  (_, _, _, ph) <-
    createProcess
      ( proc wasmInterpDyLD $
          [wasmInterpLibDir, ghci_so_path, show wfd1, show rfd2]
            ++ wasmInterpOpts
            ++ ["+RTS", "-H64m", "-RTS"]
      ) { env = Just dyld_env }
  Posix.closeFd wfd1
  Posix.closeFd rfd2
  rh <- Posix.fdToHandle rfd1
  wh <- Posix.fdToHandle wfd2
  hSetBuffering wh NoBuffering
  hSetBuffering rh NoBuffering
  interpPipe <- mkPipeFromHandles rh wh
  pending_frees <- newMVar []
  lock <- newMVar ()
  pure
    $ ExtInterpInstance
      { instProcess =
          InterpProcess
            { interpHandle = ph,
              interpPipe,
              interpLock = lock
            },
        instPendingFrees = pending_frees,
        instExtra = ()
      }

#else

-- Due to difficulty of using inherited pipe file descriptor in
-- nodejs, unfortunately we don't support Win32 host yet
spawnWasmInterp _ = sorry "Wasm iserv doesn't work on Win32 host yet"

#endif
