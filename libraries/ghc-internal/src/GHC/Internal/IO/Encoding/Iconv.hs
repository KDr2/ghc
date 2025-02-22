{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE CPP
           , NoImplicitPrelude
           , NondecreasingIndentation
           , UnboxedTuples
           , MagicHash
  #-}
{-# OPTIONS_HADDOCK not-home #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  GHC.Internal.IO.Encoding.Iconv
-- Copyright   :  (c) The University of Glasgow, 2008-2009
-- License     :  see libraries/base/LICENSE
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  internal
-- Portability :  non-portable
--
-- This module provides text encoding/decoding using iconv
--
-----------------------------------------------------------------------------

module GHC.Internal.IO.Encoding.Iconv (
#if !defined(mingw32_HOST_OS)
   iconvEncoding, mkIconvEncoding,
   localeEncodingName
#endif
 ) where

#include "MachDeps.h"
#include "HsBaseConfig.h"

#if defined(mingw32_HOST_OS)

-- See W1 of Note [Tracking dependencies on primitives] in GHC.Internal.Base
import GHC.Internal.Types ()

#else

import GHC.Internal.Foreign.C.Types
import GHC.Internal.Foreign.C.String (withCAString, peekCAString)
import GHC.Internal.Foreign.C.String.Encoding
import GHC.Internal.Foreign.Marshal.Utils
import GHC.Internal.Foreign.Storable
import GHC.Internal.Foreign.C.Error
import GHC.Internal.Bits
import GHC.Internal.Ptr
import GHC.Internal.Data.Maybe
import GHC.Internal.Base
import GHC.Internal.IO.Buffer
import GHC.Internal.IO.Encoding.Failure
import GHC.Internal.IO.Encoding.Types
import GHC.Internal.List (span)
import GHC.Internal.Num
import GHC.Internal.Show
import GHC.Internal.Word
import GHC.Internal.Real
import GHC.Internal.IO.Unsafe (unsafePerformIO)
import GHC.Internal.System.Posix.Internals

c_DEBUG_DUMP :: Bool
c_DEBUG_DUMP = False

iconv_trace :: String -> IO ()
iconv_trace s
 | c_DEBUG_DUMP = puts s
 | otherwise    = return ()

-- -----------------------------------------------------------------------------
-- iconv encoders/decoders

{-# NOINLINE localeEncodingName #-}
localeEncodingName :: String
localeEncodingName = unsafePerformIO $ do
   -- Use locale_charset() or nl_langinfo(CODESET) to get the encoding
   -- if we have either of them.
   cstr <- c_localeEncoding
   peekCAString cstr -- Assume charset names are ASCII

-- We hope iconv_t is a storable type.  It should be, since it has at least the
-- value -1, which is a possible return value from iconv_open.
type IConv = CLong -- ToDo: (#type iconv_t)

foreign import ccall unsafe "hs_iconv_open"
    hs_iconv_open :: CString -> CString -> IO IConv

foreign import ccall unsafe "hs_iconv_close"
    hs_iconv_close :: IConv -> IO CInt

foreign import ccall unsafe "hs_iconv"
    hs_iconv :: IConv -> Ptr CString -> Ptr CSize -> Ptr CString -> Ptr CSize
          -> IO CSize

foreign import ccall unsafe "localeEncoding"
    c_localeEncoding :: IO CString

haskellChar :: String
#if defined(WORDS_BIGENDIAN)
haskellChar | charSize == 2 = "UTF-16BE"
            | otherwise     = "UTF-32BE"
#else
haskellChar | charSize == 2 = "UTF-16LE"
            | otherwise     = "UTF-32LE"
#endif

char_shift :: Int
char_shift | charSize == 2 = 1
           | otherwise     = 2

iconvEncoding :: String -> IO (Maybe TextEncoding)
iconvEncoding = mkIconvEncoding ErrorOnCodingFailure

-- | Construct an iconv-based 'TextEncoding' for the given character set and
-- 'CodingFailureMode'.
--
-- As iconv is missing in some minimal environments (e.g. #10298), this
-- checks to ensure that iconv is working properly before returning the
-- encoding, returning 'Nothing' if not.
mkIconvEncoding :: CodingFailureMode -> String -> IO (Maybe TextEncoding)
mkIconvEncoding cfm charset = do
    let enc = TextEncoding {
                  textEncodingName = charset,
                  mkTextDecoder = newIConv raw_charset (haskellChar ++ suffix)
                                           (recoverDecode cfm) iconvDecode,
                  mkTextEncoder = newIConv haskellChar charset
                                           (recoverEncode cfm) iconvEncode}
    good <- charIsRepresentable enc 'a'
    return $ if good
               then Just enc
               else Nothing
  where
    -- An annoying feature of GNU iconv is that the //PREFIXES only take
    -- effect when they appear on the tocode parameter to iconv_open:
    (raw_charset, suffix) = span (/= '/') charset

newIConv :: String -> String
   -> (Buffer a -> Buffer b -> IO (Buffer a, Buffer b))
   -> (IConv -> Buffer a -> Buffer b -> IO (CodingProgress, Buffer a, Buffer b))
   -> IO (BufferCodec a b ())
newIConv from to rec fn =
  -- Assume charset names are ASCII
  withCAString from $ \ from_str ->
  withCAString to   $ \ to_str -> do
    iconvt <- throwErrnoIfMinus1 "mkTextEncoding" $ hs_iconv_open to_str from_str
    let iclose = throwErrnoIfMinus1_ "Iconv.close" $ hs_iconv_close iconvt
        fn_iconvt ibuf obuf st = case unIO (fn iconvt ibuf obuf) st of
          (# st', (prog, ibuf', obuf') #) -> (# st', prog, ibuf', obuf' #)
    return BufferCodec# {
                encode#   = fn_iconvt,
                recover#  = rec#,
                close#    = iclose,
                -- iconv doesn't supply a way to save/restore the state
                getState# = return (),
                setState# = const $ return ()
                }
  where
    rec# ibuf obuf st = case unIO (rec ibuf obuf) st of
      (# st', (ibuf', obuf') #) -> (# st', ibuf', obuf' #)

iconvDecode :: IConv -> Buffer Word8 -> Buffer Char -> IO (CodingProgress, Buffer Word8, Buffer Char)
iconvDecode iconv_t ibuf obuf = iconvRecode iconv_t ibuf 0 obuf char_shift

iconvEncode :: IConv -> Buffer Char -> Buffer Word8 -> IO (CodingProgress, Buffer Char, Buffer Word8)
iconvEncode iconv_t ibuf obuf = iconvRecode iconv_t ibuf char_shift obuf 0

iconvRecode :: IConv -> Buffer a -> Int -> Buffer b -> Int
            -> IO (CodingProgress, Buffer a, Buffer b)
iconvRecode iconv_t
  input@Buffer{  bufRaw=iraw, bufL=ir, bufR=iw, bufSize=_  }  iscale
  output@Buffer{ bufRaw=oraw, bufL=_,  bufR=ow, bufSize=os }  oscale
  = do
    iconv_trace ("haskellChar=" ++ show haskellChar)
    iconv_trace ("iconvRecode before, input=" ++ show (summaryBuffer input))
    iconv_trace ("iconvRecode before, output=" ++ show (summaryBuffer output))
    withRawBuffer iraw $ \ piraw -> do
    withRawBuffer oraw $ \ poraw -> do
    with (piraw `plusPtr` (ir `shiftL` iscale)) $ \ p_inbuf -> do
    with (poraw `plusPtr` (ow `shiftL` oscale)) $ \ p_outbuf -> do
    with (fromIntegral ((iw-ir) `shiftL` iscale)) $ \ p_inleft -> do
    with (fromIntegral ((os-ow) `shiftL` oscale)) $ \ p_outleft -> do
      res <- hs_iconv iconv_t p_inbuf p_inleft p_outbuf p_outleft
      new_inleft  <- peek p_inleft
      new_outleft <- peek p_outleft
      let
          new_inleft'  = fromIntegral new_inleft `shiftR` iscale
          new_outleft' = fromIntegral new_outleft `shiftR` oscale
          new_input
            | new_inleft == 0  = input { bufL = 0, bufR = 0 }
            | otherwise        = input { bufL = iw - new_inleft' }
          new_output = output{ bufR = os - new_outleft' }
      iconv_trace ("iconv res=" ++ show res)
      iconv_trace ("iconvRecode after,  input=" ++ show (summaryBuffer new_input))
      iconv_trace ("iconvRecode after,  output=" ++ show (summaryBuffer new_output))
      if (res /= -1)
        then -- all input translated
           return (InputUnderflow, new_input, new_output)
        else do
      errno <- getErrno
      case errno of
        e | e == e2BIG  -> return (OutputUnderflow, new_input, new_output)
          | e == eINVAL -> return (InputUnderflow, new_input, new_output)
           -- Sometimes iconv reports EILSEQ for a
           -- character in the input even when there is no room
           -- in the output; in this case we might be about to
           -- change the encoding anyway, so the following bytes
           -- could very well be in a different encoding.
           --
           -- Because we can only say InvalidSequence if there is at least
           -- one element left in the output, we have to special case this.
          | e == eILSEQ -> return (if new_outleft' == 0 then OutputUnderflow else InvalidSequence, new_input, new_output)
          | otherwise -> do
              iconv_trace ("iconv returned error: " ++ show (errnoToIOError "iconv" e Nothing Nothing))
              throwErrno "iconvRecoder"

#endif /* !mingw32_HOST_OS */

