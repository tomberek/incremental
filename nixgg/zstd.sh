#!/usr/bin/env bash
# Build zstd's static library through nixgg. Plain Makefile project,
# no autoconf; the env from `nixgg env` is sufficient.
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
export NIXGG_THUNKS_DIR="$ZSTD_SRC/.nixgg/thunks"

# Zstd's Makefile parameterises the build dir on a hash of the flags,
# so the archive lands at obj/conf_<hash>/static/libzstd.a. Rather than
# recomputing that hash, ask `make -n` where it'll build and force
# whatever file it names.
cd "$ZSTD_SRC/lib"
archive=$(make -n libzstd.a 2>/dev/null \
  | awk '/^ar/ { for (i=1;i<=NF;i++) if ($i ~ /libzstd\.a$/) { print $i; exit } }')
[[ -n "$archive" ]] || archive="libzstd.a"
exec nixgg build --target "$archive" -- make -j"$NIXGG_JOBS" libzstd.a
