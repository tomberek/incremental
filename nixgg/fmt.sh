#!/usr/bin/env bash
# Build fmt through nixgg. Fmt uses CMake — we need cmake+ninja on
# PATH — so we layer the flake's fmt-env dev shell on top of nixgg.
#
# Cmake's compiler probes need runnable binaries synchronously (same
# as autoconf conftests). The compile shim's mode logic recognises
# their filenames (test?Compiler*, CheckXxx*, CMakeFiles/CMakeScratch/*)
# and realises those specific TUs while everything else stays
# placeholder-mode.
#
# Env knobs:
#   FMT_SRC     existing checkout (default: /tmp/fmt-nixgg)
#   NIXGG_JOBS  -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FMT_SRC="${FMT_SRC:-/tmp/fmt-nixgg}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$FMT_SRC" ]]; then
  printf '==> Cloning fmt into %s\n' "$FMT_SRC" >&2
  git clone --depth=1 --branch 11.0.2 https://github.com/fmtlib/fmt.git "$FMT_SRC"
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

  cd "'"$FMT_SRC"'"
  # Fresh build dir keeps the demo predictable.
  rm -rf build && mkdir build

  # Configure: cmake compiler probes run in the shim; conftest-shaped
  # filenames get auto-realise-mode so probes see real .o files.
  cmake -S . -B build \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DFMT_TEST=OFF -DFMT_DOC=OFF \
    -DBUILD_SHARED_LIBS=OFF

  # Build: link shim auto-forces. libfmt.a is an archive, not a link,
  # so we still need `nixgg force` at the end to materialise it —
  # unless we drove cmake to produce a binary.
  export NIXGG_AUTOFORCE=1
  cmake --build build -j'"$NIXGG_JOBS"'

  # The output is an archive (no link step to trigger auto-force);
  # explicitly realise it.
  nixgg force build/libfmt.a

  ls -l build/libfmt.a
'
