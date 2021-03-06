{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE ViewPatterns        #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.CodeGen
-- Copyright   : [2015] Trevor L. McDonell
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.CodeGen (

  Skeleton(..), Expression(..), Intrinsic(..),
  llvmOfOpenAcc,

) where

-- accelerate
import Data.Array.Accelerate.AST                                hiding ( Val(..), prj, stencil )
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Trafo
import Data.Array.Accelerate.Type

import Data.Array.Accelerate.LLVM.Target

import Data.Array.Accelerate.LLVM.CodeGen.Constant
import Data.Array.Accelerate.LLVM.CodeGen.Environment
import Data.Array.Accelerate.LLVM.CodeGen.Exp
import Data.Array.Accelerate.LLVM.CodeGen.IR
import Data.Array.Accelerate.LLVM.CodeGen.Intrinsic
import Data.Array.Accelerate.LLVM.CodeGen.Module
import Data.Array.Accelerate.LLVM.CodeGen.Monad
import Data.Array.Accelerate.LLVM.CodeGen.Skeleton
import Data.Array.Accelerate.LLVM.CodeGen.Sugar

-- standard library
import Prelude                                                  hiding ( map, scanl, scanl1, scanr, scanr1 )


-- | Generate code for a given target architecture.
--
llvmOfOpenAcc
    :: forall arch aenv arrs. (Target arch, Skeleton arch, Intrinsic arch, Expression arch)
    => arch
    -> DelayedOpenAcc aenv arrs
    -> Gamma aenv
    -> Module arch aenv arrs
llvmOfOpenAcc _    Delayed{}       _    = $internalError "llvmOfOpenAcc" "expected manifest array"
llvmOfOpenAcc arch (Manifest pacc) aenv = runLLVM $
  case pacc of
    -- Producers
    Map f a                 -> map arch aenv (travF1 f) (travD a)
    Generate _ f            -> generate arch aenv (travF1 f)
    Transform _ p f a       -> transform arch aenv (travF1 p) (travF1 f) (travD a)
    Backpermute _ p a       -> backpermute arch aenv (travF1 p) (travD a)

    -- Consumers
    Fold f z a              -> fold arch aenv (travF2 f) (travE z) (travD a)
    Fold1 f a               -> fold1 arch aenv (travF2 f) (travD a)
    FoldSeg f z a s         -> foldSeg arch aenv (travF2 f) (travE z) (travD a) (travD s)
    Fold1Seg f a s          -> fold1Seg arch aenv (travF2 f) (travD a) (travD s)
    Scanl f z a             -> scanl arch aenv (travF2 f) (travE z) (travD a)
    Scanl' f z a            -> scanl' arch aenv (travF2 f) (travE z) (travD a)
    Scanl1 f a              -> scanl1 arch aenv (travF2 f) (travD a)
    Scanr f z a             -> scanr arch aenv (travF2 f) (travE z) (travD a)
    Scanr' f z a            -> scanr' arch aenv (travF2 f) (travE z) (travD a)
    Scanr1 f a              -> scanr1 arch aenv (travF2 f) (travD a)
    Permute f _ p a         -> permute arch aenv (travF2 f) (travF1 p) (travD a)
    Stencil f b a           -> stencil arch aenv (travF1 f) (travB a b) (travM a)
    Stencil2 f b1 a1 b2 a2  -> stencil2 arch aenv (travF2 f) (travB a1 b1) (travM a1) (travB a2 b2) (travM a2)

    -- Non-computation forms: sadness
    Alet{}                  -> unexpectedError pacc
    Avar{}                  -> unexpectedError pacc
    Apply{}                 -> unexpectedError pacc
    Acond{}                 -> unexpectedError pacc
    Awhile{}                -> unexpectedError pacc
    Atuple{}                -> unexpectedError pacc
    Aprj{}                  -> unexpectedError pacc
    Use{}                   -> unexpectedError pacc
    Unit{}                  -> unexpectedError pacc
    Aforeign{}              -> unexpectedError pacc
    Reshape{}               -> unexpectedError pacc

    Replicate{}             -> fusionError pacc
    Slice{}                 -> fusionError pacc
    ZipWith{}               -> fusionError pacc

  where
    -- code generation for delayed arrays
    travD :: DelayedOpenAcc aenv (Array sh e) -> IRDelayed arch aenv (Array sh e)
    travD Manifest{}  = $internalError "llvmOfOpenAcc" "expected delayed array"
    travD Delayed{..} = IRDelayed (travE extentD) (travF1 indexD) (travF1 linearIndexD)

    travM :: DelayedOpenAcc aenv (Array sh e) -> IRManifest arch aenv (Array sh e)
    travM (Manifest (Avar ix)) = IRManifest ix
    travM _                    = $internalError "llvmOfOpenAcc" "expected manifest array variable"

    -- scalar code generation
    travF1 :: DelayedFun aenv (a -> b) -> IRFun1 arch aenv (a -> b)
    travF1 f = llvmOfFun1 arch f aenv

    travF2 :: DelayedFun aenv (a -> b -> c) -> IRFun2 arch aenv (a -> b -> c)
    travF2 f = llvmOfFun2 arch f aenv

    travE :: DelayedExp aenv t -> IRExp arch aenv t
    travE e = llvmOfOpenExp arch e Empty aenv

    travB :: forall sh e. Elt e
          => DelayedOpenAcc aenv (Array sh e)
          -> Boundary (EltRepr e)
          -> Boundary (IRExp arch aenv e)
    travB _ Clamp        = Clamp
    travB _ Mirror       = Mirror
    travB _ Wrap         = Wrap
    travB _ (Constant c)
      = Constant . return
      $ IR (constant (eltType (undefined::e)) c)

    -- sadness
    unexpectedError x   = $internalError "llvmOfOpenAcc" $ "unexpected array primitive: "  ++ showPreAccOp x
    fusionError x       = $internalError "llvmOfOpenAcc" $ "unexpected fusible material: " ++ showPreAccOp x

