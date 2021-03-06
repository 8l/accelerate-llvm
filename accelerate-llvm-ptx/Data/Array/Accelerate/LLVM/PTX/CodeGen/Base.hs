{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.CodeGen.Base
-- Copyright   : [2014..2015] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.CodeGen.Base (

  -- Thread identifiers
  blockDim, gridDim, threadIdx, blockIdx, warpSize,
  gridSize, globalThreadIdx,
  gangParam,

  -- Barriers and synchronisation
  __syncthreads,
  __threadfence_block, __threadfence_grid,

  --- Kernel definitions
  makeOpenAcc,

) where

import Control.Monad                                                    ( void )

-- llvm
import LLVM.General.AST.Type.Global
import LLVM.General.AST.Type.Constant
import LLVM.General.AST.Type.Operand
import LLVM.General.AST.Type.Metadata
import LLVM.General.AST.Type.Name
import qualified LLVM.General.AST.Global                                as LLVM
import qualified LLVM.General.AST.Type                                  as LLVM

-- accelerate
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.LLVM.CodeGen.Arithmetic                    as A
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Constant
import Data.Array.Accelerate.LLVM.CodeGen.Downcast
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Module
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Sugar


-- Thread identifiers
-- ------------------

-- | Read the builtin registers that store CUDA thread and grid identifiers
--
specialPTXReg :: Label -> CodeGen (IR Int32)
specialPTXReg f =
  call (Body (Just scalarType) f) [NoUnwind, ReadNone]

blockDim, gridDim, threadIdx, blockIdx, warpSize :: CodeGen (IR Int32)
blockDim  = specialPTXReg "llvm.nvvm.read.ptx.sreg.ntid.x"
gridDim   = specialPTXReg "llvm.nvvm.read.ptx.sreg.nctaid.x"
threadIdx = specialPTXReg "llvm.nvvm.read.ptx.sreg.tid.x"
blockIdx  = specialPTXReg "llvm.nvvm.read.ptx.sreg.ctaid.x"
warpSize  = specialPTXReg "llvm.nvvm.read.ptx.sreg.warpsize"


-- | The size of the thread grid
--
-- > gridDim.x * blockDim.x
--
gridSize :: CodeGen (IR Int32)
gridSize = do
  ncta  <- gridDim
  nt    <- blockDim
  mul numType ncta nt


-- | The global thread index
--
-- > blockDim.x * blockIdx.x + threadIdx.x
--
globalThreadIdx :: CodeGen (IR Int32)
globalThreadIdx = do
  ntid  <- blockDim
  ctaid <- blockIdx
  tid   <- threadIdx

  u     <- mul numType ntid ctaid
  v     <- add numType tid u
  return v


-- | Generate function parameters that will specify the first and last (linear)
-- index of the array this kernel should evaluate.
--
gangParam :: (IR Int32, IR Int32, [LLVM.Parameter])
gangParam =
  let t         = scalarType
      start     = "ix.start"
      end       = "ix.end"
  in
  (local t start, local t end, [ scalarParameter t start, scalarParameter t end ] )


-- Barriers and synchronisation
-- ----------------------------

-- | Call a builtin CUDA synchronisation intrinsic
--
barrier :: Label -> CodeGen ()
barrier f = void $ call (Body Nothing f) [NoUnwind, ReadNone]


-- | Wait until all threads in the thread block have reached this point and all
-- global and shared memory accesses made by these threads prior to
-- __syncthreads() are visible to all threads in the block.
--
-- <http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#synchronization-functions>
--
__syncthreads :: CodeGen ()
__syncthreads = barrier "llvm.nvvm.barrier0"


-- | Ensure that all writes to shared and global memory before the call to
-- __threadfence_block() are observed by all threads in the *block* of the
-- calling thread as occurring before all writes to shared and global memory
-- made by the calling thread after the call.
--
-- <http://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#memory-fence-functions>
--
__threadfence_block :: CodeGen ()
__threadfence_block = barrier "llvm.nvvm.membar.cta"


-- | As __threadfence_block(), but the synchronisation is for *all* thread blocks.
-- In CUDA this is known simply as __threadfence().
--
__threadfence_grid :: CodeGen ()
__threadfence_grid = barrier "llvm.nvvm.membar.gl"


-- Global kernel definitions
-- -------------------------


-- | Create a single kernel program
--
makeOpenAcc :: Label -> [LLVM.Parameter] -> CodeGen () -> CodeGen (IROpenAcc arch aenv a)
makeOpenAcc name param kernel = do
  body <- makeKernel name param kernel
  return $ IROpenAcc [body]

-- | Create a complete kernel function by running the code generation process
-- specified in the final parameter.
--
makeKernel :: Label -> [LLVM.Parameter] -> CodeGen () -> CodeGen (Kernel arch aenv a)
makeKernel name@(Label l) param kernel = do
  _    <- kernel
  code <- createBlocks
  addMetadata "nvvm.annotations"
    [ Just . MetadataOperand       $ ConstantOperand (GlobalReference Nothing (Name l))
    , Just . MetadataStringOperand $ "kernel"
    , Just . MetadataOperand       $ scalar scalarType (1::Int)
    ]
  return . Kernel $ LLVM.functionDefaults
    { LLVM.returnType  = LLVM.VoidType
    , LLVM.name        = downcast name
    , LLVM.parameters  = (param, False)
    , LLVM.basicBlocks = code
    }

