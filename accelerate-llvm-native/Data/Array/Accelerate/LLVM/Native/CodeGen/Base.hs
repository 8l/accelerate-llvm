{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.CodeGen.Base
-- Copyright   : [2015] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.CodeGen.Base
  where

-- llvm-general
import qualified LLVM.General.AST.Global                                as LLVM
import qualified LLVM.General.AST.Type                                  as LLVM

-- accelerate
import Data.Array.Accelerate.Type

-- accelerate-llvm
import LLVM.General.AST.Type.Name

import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Downcast
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Module
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Sugar


-- | Generate function parameters that will specify the first and last (linear)
-- index of the array this thread should evaluate.
--
gangParam :: (IR Int, IR Int, [LLVM.Parameter])
gangParam =
  let t         = scalarType
      start     = "ix.start"
      end       = "ix.end"
  in
  (local t start, local t end, [ scalarParameter t start, scalarParameter t end ] )


-- | The thread ID of a gang worker
--
gangId :: (IR Int, [LLVM.Parameter])
gangId =
  let t         = scalarType
      tid       = "ix.tid"
  in
  (local t tid, [ scalarParameter t tid ] )


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
makeKernel name param kernel = do
  _    <- kernel
  code <- createBlocks
  return . Kernel $ LLVM.functionDefaults
             { LLVM.returnType  = LLVM.VoidType
             , LLVM.name        = downcast name
             , LLVM.parameters  = (param, False)
             , LLVM.basicBlocks = code
             }

