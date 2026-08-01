#!/usr/bin/env bash
# Point nixgg at fmt's CMake build. Two-phase like mosh.sh:
#   1. `cmake -B build` in realise mode so its compiler probes get real
#      results (widen `_mode_for` covered the auto-detected filenames).
#   2. `cmake --build build` in placeholder mode → `nixgg force` on the
#      chosen target.
#
# Env knobs:
#   FMT_SRC           existing checkout to build (default: /tmp/nixgg-fmt/fmt)
#   NIXGG_JOBS        -j level (default: nproc)
#   NIXGG_STAGE_ONLY  =1 → drop into nix develop .#fmt-env instead

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
FMT_SRC="${FMT_SRC:-/tmp/nixgg-fmt/fmt}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
[[ -x "$BOOTSTRAP_NIX" ]] || fail "no nix on PATH"

if [[ ! -d "$FMT_SRC" ]]; then
  info "Cloning fmt into $FMT_SRC"
  mkdir -p "$(dirname "$FMT_SRC")"
  git clone --depth=1 --branch 11.0.2 https://github.com/fmtlib/fmt.git "$FMT_SRC"
fi

if [[ "${NIXGG_STAGE_ONLY:-0}" == "1" ]]; then
  info "NIXGG_STAGE_ONLY=1 — dropping into nix develop .#fmt-env"
  exec "$BOOTSTRAP_NIX" develop "$here#fmt-env"
fi

export FMT_SRC NIXGG_JOBS
INNER_SCRIPT='
set -euo pipefail
cd "$FMT_SRC"

# Fresh build dir each time keeps the demo simple.
rm -rf build
mkdir build

GEN="${NIXGG_CMAKE_GEN:-Unix Makefiles}"

# 1. cmake configure — realise mode. Probes need real .o outputs.
"'"$here"'/nixgg" run -- cmake -S . -B build -G "$GEN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DFMT_TEST=OFF \
  -DFMT_DOC=OFF \
  -DBUILD_SHARED_LIBS=OFF 2>&1 | tail -5

# 2. cmake build — either straight realise, or placeholder + force.
if [[ "${NIXGG_MODE:-realise}" == placeholder ]]; then
  "'"$here"'/nixgg" build \
    --target build/libfmt.a \
    -- cmake --build build -j"$NIXGG_JOBS"
else
  "'"$here"'/nixgg" run -- cmake --build build -j"$NIXGG_JOBS"
fi

ls -l build/libfmt.a
'

exec "$BOOTSTRAP_NIX" develop "$here#fmt-env" --command bash -c "$INNER_SCRIPT"
