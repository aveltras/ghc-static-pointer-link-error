#!/usr/bin/env bash
set -u
ghc="${GHC:-ghc}"
for flags in "-O0" "-O1" "-O1 -fno-specialise"; do
  out="$(mktemp -d)"
  if "$ghc" $flags -outputdir "$out" -o "$out/main" Main.hs > "$out/log" 2>&1; then
    echo "$flags: OK"
  else
    echo "$flags: FAILED"
    grep -E "undefined reference" "$out/log"
  fi
  rm -rf "$out"
done
