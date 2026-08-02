#!/usr/bin/env bash
# Point nixgg at the redis build. Pure Makefile — no autoconf. ~150 TUs
# in src/, so this is a decent stress test of the shim overhead vs. the
# Nix eval cache. Toolchain + system deps come from the flake.
#
# Env knobs:
#   REDIS_SRC         existing checkout to build (default: clone under /tmp)
#   NIXGG_JOBS        -j level for make (default: nproc)
#   NIXGG_MODE        realise (default) or placeholder
#   NIXGG_STAGE_ONLY  set to 1 to drop into an interactive
#                     `nix develop` shell instead of building
#
# The reference numbers on my machine (~/incremental, 8-core):
#   cold  build   ~37s
#   warm  rebuild ~18s   (all cache-hits, shim overhead × ~150 TUs)
#   edit  rebuild  ~8s   (touch one .c → recompile it + link)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
REDIS_SRC="${REDIS_SRC:-/tmp/nixgg-redis/redis}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
[[ -x "$BOOTSTRAP_NIX" ]] || fail "no nix on PATH"

if [[ ! -d "$REDIS_SRC" ]]; then
  info "Cloning redis into $REDIS_SRC"
  mkdir -p "$(dirname "$REDIS_SRC")"
  git clone --depth=1 https://github.com/redis/redis.git "$REDIS_SRC"
fi

if [[ "${NIXGG_STAGE_ONLY:-0}" == "1" ]]; then
  info "NIXGG_STAGE_ONLY=1 — dropping into nix develop .#mosh-env"
  exec "$BOOTSTRAP_NIX" develop "$here#mosh-env"
fi

# Redis has no autoconf; just `cd src && make redis-server`. We reuse
# mosh-env because it already carries gnumake + pkg-config.
#
# SOURCE_DATE_EPOCH pins mkreleasehdr.sh's BUILD_ID (otherwise
# "<hostname>-<epoch>" gets baked into release.o, defeating CA-caching).
export REDIS_SRC NIXGG_JOBS
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
INNER_SCRIPT='
set -euo pipefail
cd "$REDIS_SRC"
# On a fresh clone `.make-prerequisites` doesn'"'"'t exist yet — running
# `persist-settings` seeds redis'"'"'s settings-tracking machinery. Once
# it exists, we skip it: redis'"'"'s Makefile only auto-triggers a
# persist-settings (= distclean) when FINAL_CFLAGS actually changed,
# and forcing it unconditionally wipes every intermediate every build.
if [[ ! -f src/.make-prerequisites ]]; then
  "'"$here"'/nixgg" run -- make -C src -j"$NIXGG_JOBS" MALLOC=libc persist-settings
fi
"'"$here"'/nixgg" run -- make -C deps -j"$NIXGG_JOBS" \
    hiredis linenoise lua hdr_histogram fpconv xxhash tre

cd "$REDIS_SRC/src"
if [[ "${NIXGG_MODE:-realise}" == placeholder ]]; then
  "'"$here"'/nixgg" build --target redis-server -- make MALLOC=libc -j"$NIXGG_JOBS"
else
  "'"$here"'/nixgg" run -- make MALLOC=libc -j"$NIXGG_JOBS" redis-server
fi
'

exec "$BOOTSTRAP_NIX" develop "$here#mosh-env" --command bash -c "$INNER_SCRIPT"
