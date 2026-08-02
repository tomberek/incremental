#!/usr/bin/env bash
# Build lua 5.4 through nixgg. Lua is a plain Makefile project — it
# doesn't need autoconf, cmake, or protoc — so `eval $(nixgg env)`
# gives us everything: gcc, make, and the shims that intercept them.
#
# Env knobs:
#   LUA_SRC     existing checkout (default: /tmp/lua-5.4.7)
#   NIXGG_JOBS  -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LUA_SRC="${LUA_SRC:-/tmp/lua-5.4.7}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$LUA_SRC" ]]; then
  printf '==> Downloading lua into %s\n' "$LUA_SRC" >&2
  mkdir -p "$(dirname "$LUA_SRC")"
  ( cd "$(dirname "$LUA_SRC")" \
    && curl -sSL https://www.lua.org/ftp/lua-5.4.7.tar.gz | tar xz )
fi

eval "$("$here/bin/nixgg" env)"
export NIXGG_THUNKS_DIR="$LUA_SRC/.nixgg/thunks"

# `linux` recurses into `make ... SYSCFLAGS=… all`, which is where the
# actual compile shims fire. --target lua/luac names the final binaries.
cd "$LUA_SRC/src"
exec nixgg build --target lua --target luac -- make -j"$NIXGG_JOBS" linux
