{-# LANGUAGE StaticPointers #-}
module Repro (build) where

import GHC.StaticPtr (StaticPtr)

build :: (StaticPtr (IO ()), StaticPtr (IO ()))
build = let p = static (pure ()) in (p, p)
{-# NOINLINE build #-}
