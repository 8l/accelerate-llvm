{-# LANGUAGE CPP             #-}
{-# LANGUAGE EmptyDataDecls  #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.Target
-- Copyright   : [2014] Trevor L. McDonell, Sean Lee, Vinod Grover, NVIDIA Corporation
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.Target (

  module Data.Array.Accelerate.LLVM.Target,
  module Data.Array.Accelerate.LLVM.PTX.Target,

) where

-- llvm-general
import LLVM.General.AST.AddrSpace
import LLVM.General.AST.DataLayout
import LLVM.General.Target                                      hiding ( Target )
import qualified LLVM.General.Target                            as LLVM
import qualified LLVM.General.Relocation                        as R
import qualified LLVM.General.CodeModel                         as CM
import qualified LLVM.General.CodeGenOpt                        as CGO

-- accelerate
import Data.Array.Accelerate.Error

import Data.Array.Accelerate.LLVM.Target
import Data.Array.Accelerate.LLVM.Util

import Control.Parallel.Meta                                    ( Executable )
import Data.Array.Accelerate.LLVM.PTX.Context                   ( Context, deviceProperties )
import Data.Array.Accelerate.LLVM.PTX.Array.Table               ( MemoryTable )
import Data.Array.Accelerate.LLVM.PTX.Execute.Stream            ( Reservoir )

-- CUDA
import qualified Foreign.CUDA.Driver                            as CUDA

-- standard library
import Control.Monad.Except
import System.IO.Unsafe
import Text.Printf
import qualified Data.Map                                       as Map
import qualified Data.Set                                       as Set


-- | The PTX execution target for NVIDIA GPUs.
--
-- The execution target carries state specific for the current execution
-- context. The data here --- device memory and execution streams --- are
-- implicitly tied to this CUDA execution context.
--
-- Don't store anything here that is independent of the context, for example
-- state related to [persistent] kernel caching should _not_ go here.
--
data PTX = PTX {
    ptxContext                  :: {-# UNPACK #-} !Context
  , ptxMemoryTable              :: {-# UNPACK #-} !MemoryTable
  , ptxStreamReservoir          :: {-# UNPACK #-} !Reservoir
  , fillP                       :: {-# UNPACK #-} !Executable
  }

instance Target PTX where
  targetTriple _     = Just ptxTargetTriple
  targetDataLayout _ = Just ptxDataLayout


-- | Extract the properties of the device the current PTX execution state is
-- executing on.
--
ptxDeviceProperties :: PTX -> CUDA.DeviceProperties
ptxDeviceProperties = deviceProperties . ptxContext


-- | A description of the various data layout properties that may be used during
-- optimisation. For CUDA the following data layouts are supported:
--
-- 32-bit:
--   e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v32:32:32-v64:64:64-v128:128:128-n16:32:64
--
-- 64-bit:
--   e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v32:32:32-v64:64:64-v128:128:128-n16:32:64
--
-- Thus, only the size of the pointer layout changes depending on the host
-- architecture.
--
ptxDataLayout :: DataLayout
ptxDataLayout = DataLayout
  { endianness          = Just LittleEndian
  , stackAlignment      = Nothing
  , pointerLayouts      = Map.fromList
      [ (AddrSpace 0, (wordSize, AlignmentInfo wordSize (Just wordSize))) ]
  , typeLayouts         = Map.fromList $
      [ ((IntegerAlign, 1), AlignmentInfo 8 (Just 8)) ] ++
      [ ((IntegerAlign, i), AlignmentInfo i (Just i)) | i <- [8,16,32,64]] ++
      [ ((VectorAlign,  v), AlignmentInfo v (Just v)) | v <- [16,32,64,128]] ++
      [ ((FloatAlign,   f), AlignmentInfo f (Just f)) | f <- [32,64] ]
  , nativeSizes         = Just $ Set.fromList [ 16,32,64 ]
  }
  where
    wordSize = bitSize (undefined :: Int)


-- | String that describes the target host.
--
ptxTargetTriple :: String
ptxTargetTriple =
  case bitSize (undefined::Int) of
    32  -> "nvptx-nvidia-cuda"
    64  -> "nvptx64-nvidia-cuda"
    _   -> $internalError "ptxTargetTriple" "I don't know what architecture I am"


-- | Bracket creation and destruction of the NVVM TargetMachine.
--
withPTXTargetMachine
    :: CUDA.DeviceProperties
    -> (TargetMachine -> IO a)
    -> IO a
withPTXTargetMachine dev go =
  let CUDA.Compute m n = CUDA.computeCapability dev
      sm               = printf "sm_%d%d" m n
  in
  withTargetOptions $ \options -> do
    withTargetMachine
        ptxTarget
        ptxTargetTriple
        sm
        Set.empty               -- CPU features
        options                 -- target options
        R.Default               -- relocation model
        CM.Default              -- code model
        CGO.Default             -- optimisation level
        go


-- | The NVPTX target for this host.
--
-- The top-level 'unsafePerformIO' is so that 'initializeAllTargets' is run once
-- per program execution (although that might not be necessary?)
--
{-# NOINLINE ptxTarget #-}
ptxTarget :: LLVM.Target
ptxTarget = unsafePerformIO $ do
  initializeAllTargets
  either error fst `fmap` runExceptT (lookupTarget Nothing ptxTargetTriple)

