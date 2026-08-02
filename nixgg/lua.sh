#!/usr/bin/env bash
# Build lua 5.4 through nixgg.
#
# Lua is a good incremental benchmark for us: pure Makefile, ~34 C files,
# no autoconf/conftest chaos, and plain `make` correctly says "Nothing to
# be done" on a warm no-op (redis force-runs distclean via
# .make-prerequisites, which makes it useless for incremental measurement).
#
# Env knobs:
#   LUA_SRC          existing checkout to build (default: /tmp/lua-5.4.7)
#   NIXGG_JOBS       -j level for make (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LUA_TARBALL_URL="https://www.lua.org/ftp/lua-5.4.7.tar.gz"
LUA_SRC="${LUA_SRC:-/tmp/lua-5.4.7}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
[[ -x "$BOOTSTRAP_NIX" ]] || fail "no nix on PATH"

# Cache the mosh-env dev shell as a nix profile — subsequent runs skip
# flake evaluation. mosh-env has make + a modern gcc + all standard
# toolchain bits, which is all lua needs.
CACHE_DIR="${NIXGG_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nixgg}"
PROFILE="$CACHE_DIR/mosh-env"
ENV_SH="$CACHE_DIR/mosh-env.sh"
if [[ ! -L "$PROFILE" ]]; then
  info "Building nixgg profile at $PROFILE"
  mkdir -p "$CACHE_DIR"
  "$BOOTSTRAP_NIX" develop "$here#mosh-env" --profile "$PROFILE" --command true
fi
if [[ ! -f "$ENV_SH" || "$PROFILE" -nt "$ENV_SH" ]]; then
  info "Extracting dev-shell env into $ENV_SH"
  "$BOOTSTRAP_NIX" develop "$PROFILE" --command bash -c '
    for v in PATH PKG_CONFIG_PATH \
             NIX_CFLAGS_COMPILE NIX_CFLAGS_COMPILE_x86_64_unknown_linux_gnu \
             NIX_LDFLAGS NIX_LDFLAGS_x86_64_unknown_linux_gnu \
             NIX_HARDENING_ENABLE NIX_HARDENING_ENABLE_x86_64_unknown_linux_gnu \
             NIX_CC_WRAPPER_TARGET_HOST_x86_64_unknown_linux_gnu \
             CC CXX SOURCE_DATE_EPOCH; do
      val="${!v:-}"
      [[ -n "$val" ]] && printf "export %s=%q\n" "$v" "$val"
    done
  ' > "$ENV_SH.tmp"
  mv "$ENV_SH.tmp" "$ENV_SH"
fi

if [[ ! -d "$LUA_SRC" ]]; then
  info "Downloading lua into $LUA_SRC"
  mkdir -p "$(dirname "$LUA_SRC")"
  ( cd "$(dirname "$LUA_SRC")" && curl -sSL "$LUA_TARBALL_URL" | tar xz )
fi

# The env-shell package exports NIXGG_REAL_CC, NIXGG_NIX_HELPERS, etc —
# the toolchain roots our Go shim needs. mosh-env.sh (extracted above)
# gives PATH + NIX_CFLAGS_COMPILE, which the compiler wrapper reads
# inside the sandbox derivations.
NIXGG_ENV_SHELL=$("$BOOTSTRAP_NIX" build "$here#env-shell" --no-link --print-out-paths)
export NIXGG_ENV_SHELL
export NIXGG_STORE="${NIXGG_STORE:-local?root=/tmp/nixgg-store}"
export LUA_SRC NIXGG_JOBS

# Fresh shell, sourced env, straight through to nixgg build. `linux`
# is the lua build target that produces src/lua and src/luac.
exec bash -c "
  set -euo pipefail
  set -a
  . '$ENV_SH'
  . '$NIXGG_ENV_SHELL'
  set +a
  export NIXGG_THUNKS_DIR='$LUA_SRC/.nixgg/thunks'
  cd '$LUA_SRC/src'
  '$here/bin/nixgg' build --target lua --target luac -- make -j$NIXGG_JOBS linux
"
