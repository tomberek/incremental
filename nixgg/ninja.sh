#!/usr/bin/env bash
# Build ninja through nixgg. Cmake project that produces a binary
# (./ninja), so the link shim's auto-force hook fires on the final
# link and produces a real ELF without needing `nixgg force`.
#
# Reuses the flake's fmt-env dev shell — same cmake+ninja toolchain
# fmt uses.
#
# Env knobs:
#   NINJA_SRC    existing checkout (default: /tmp/ninja-nixgg)
#   NIXGG_JOBS   -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
NINJA_SRC="${NINJA_SRC:-/tmp/ninja-nixgg}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$NINJA_SRC" ]]; then
  printf '==> Cloning ninja into %s\n' "$NINJA_SRC" >&2
  git clone --depth=1 --branch v1.12.1 https://github.com/ninja-build/ninja.git "$NINJA_SRC"
fi

BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
NIXGG_ENV_SHELL=$("$BOOTSTRAP_NIX" build "$here#env-shell" --no-link --print-out-paths)
export NIXGG_STORE="${NIXGG_STORE:-local?root=/tmp/nixgg-store}"

exec "$BOOTSTRAP_NIX" develop "$here#fmt-env" --command bash -c '
  set -euo pipefail
  set -a
  . "'"$NIXGG_ENV_SHELL"'"
  set +a
  export PATH="'"$here"'/bin:'"$here"'/shims:$PATH"
  export NIXGG_ROOT="'"$here"'"
  export CC=cc CXX=c++

  cd "'"$NINJA_SRC"'"
  rm -rf build && mkdir build

  # Configure: cmake probes (test?Compiler*, CheckXXX*) auto-realise
  # via the compile shim; everything else stays placeholder.
  cmake -S . -B build \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF

  # Build: link shim auto-forces the final ninja binary.
  export NIXGG_AUTOFORCE=1
  cmake --build build -j'"$NIXGG_JOBS"'

  ls -la build/ninja
  build/ninja --version
'
