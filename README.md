# Undefined static pointer closure when linking at `-O1`

A module that let-binds a `static` form fails to link at `-O1`. The C stub that
fills the static pointer table refers to a closure that GHC emits as a local
symbol:

```
Repro.o:ghc_tmp_5_2.c:function Repro_init__spt:(.text+0x27): error: undefined reference to 'rS7_closure'
collect2: error: ld returned 1 exit status
```

The program links at `-O0`, and at `-O1 -fno-specialise`.

## Reproduction

`Repro.hs`:

```haskell
{-# LANGUAGE StaticPointers #-}
module Repro (build) where

import GHC.StaticPtr (StaticPtr)

build :: (StaticPtr (IO ()), StaticPtr (IO ()))
build = let p = static (pure ()) in (p, p)
{-# NOINLINE build #-}
```

`Main.hs`:

```haskell
import Repro (build)

main :: IO ()
main = build `seq` pure ()
```

Run `./repro.sh`, or set `GHC` to choose the compiler (`GHC=ghc-9.14.1 ./repro.sh`).
It builds `Main.hs` with each set of flags:

| GHC    | `-O0` | `-O1`                                 | `-O1 -fno-specialise` |
| ------ | ----- | ------------------------------------- | --------------------- |
| 9.12.4 | OK    | `undefined reference to 'rR3_closure'` | OK                    |
| 9.14.1 | OK    | `undefined reference to 'rS7_closure'` | OK                    |

Tested on x86_64-linux with GCC 15.2 as the C compiler and linker driver.

All three ingredients are needed:

- the `static` form is bound by a `let`,
- the binding is used more than once, so it is not inlined,
- the enclosing binding exposes no unfolding (`NOINLINE` here; a large
  function has the same effect).

## What happens

The desugarer produces `build = let p = makeStatic loc (pure ()) in (p, p)`.

Without `-fspecialise`, the first Float Out pass meets the `makeStatic` call
and, as described in Note [Grand plan for static forms] in
`GHC.Iface.Tidy.StaticPtrTable`, floats it to a fresh exported `static_ptr`
binder (`newLvlVar` in `GHC.Core.Opt.SetLevels`). The binder keeps an external
name and its closure is a global symbol:

```
static_ptr
  = StaticPtr
      1908046912929907239#Word64
      1229824467664129749#Word64
      (StaticPtrInfo
         (unpackCString# "main"#) (unpackCString# "Repro"#) static_ptr2)
      (static_ptr1 `cast` <Co:3> :: ...)
build = (static_ptr, static_ptr)
```

```
00000000000000c0 D Repro_staticzuptr_closure
0000000000000022 T Repro_init__spt
```

With `-fspecialise`, the pipeline runs the gentle simplifier before
specialisation, so before the first Float Out. The simplifier floats the
existing `let p = makeStatic ...` to the top level as an ordinary local binder.
Float Out then sees a top-level binding instead of a `makeStatic` expression,
so the binder is never made exported. Tidy Core still turns it into a
`StaticPtr` and records it in the static pointer table, but leaves its name
internal because no exposed unfolding mentions it:

```
p = StaticPtr
      1908046912929907239#Word64
      1229824467664129749#Word64
      (StaticPtrInfo
         (unpackCString# "main"#) (unpackCString# "Repro"#) lvl2)
      (lvl3 `cast` <Co:3> :: ...)
build = (p, p)
```

The code generator emits `p` as a local symbol, while the static pointer table
stub, compiled as separate C code, needs a global one:

```
0000000000000022 T Repro_init__spt
                 U rRx_closure
```

Dropping `NOINLINE` exposes the unfolding of `build`, which mentions `p`, so
Tidy externalises it and the program links. This hides the bug rather than
avoiding it.

## Where it shows up

Cabal's `SetupHooks` API is built on static pointers, e.g.
`mkCommand (static Dict) (static action) arg`. Registering rules from a
traversal such as `traverse_ (\x -> registerRule_ ... (staticRule (mkCommand
(static Dict) (static action) ...) ...))` inlines Cabal's helpers, and the
gentle simplifier let-binds the `makeStatic` arguments. Setup scripts using
such hooks then fail to link with GHC 9.14.1 and Cabal-hooks 3.16.

## Workaround

Compile the affected modules with `-fno-specialise`, which removes the gentle
simplifier pass that creates the floated `let`.
