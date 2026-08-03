#!/usr/bin/env bash
# Build zstd (the CLI binary) through nixgg. Plain Makefile project —
# no autoconf, no cmake — so `eval $(nixgg env)` is enough.
#
# Zstd is a good cross-directory test: the `zstd` binary links .o files
# from three subtrees (lib/, programs/, programs/lib/common) all via
# recursive make. Every shim in that tree must land in one thunks dir
# so the link thunk's `import ./<id>.nix` references resolve.
#
# The Makefile also parameterises the build dir on a hash of the flags
# (obj/conf_<hash>/zstd), so we ask `make -n` where it'll write and
# force whatever file it names.
#
# Env knobs:
#   ZSTD_SRC    existing checkout (default: /tmp/zstd-nixgg)
#   NIXGG_JOBS  -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ZSTD_SRC="${ZSTD_SRC:-/tmp/zstd-nixgg}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$ZSTD_SRC" ]]; then
  printf '==> Cloning zstd into %s\n' "$ZSTD_SRC" >&2
  git clone --depth=1 https://github.com/facebook/zstd.git "$ZSTD_SRC"
fi

eval "$("$here/bin/nixgg" env)"

# NIXGG_AUTOFORCE=1: link shim realises each binary inline, so plain
# `make` produces real ELFs in the working tree. `nixgg build` /
# `nixgg force` are unneeded on projects like this.
cd "$ZSTD_SRC/programs"
exec env NIXGG_AUTOFORCE=1 make -j"$NIXGG_JOBS" zstd
