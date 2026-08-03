#!/usr/bin/env bash
# Build redis through nixgg. Plain Makefile (no autoconf/cmake), but
# nested — src/ depends on static libs in deps/*/. All shims target
# one thunks dir so cross-subdir `import ./<id>.nix` references
# resolve at force time.
#
# Redis's Makefile has some quirks that we work around:
#
#  - persist-settings: A fresh clone doesn't have .make-prerequisites,
#    and redis's normal build path won't create it — you have to invoke
#    the persist-settings target explicitly. It runs `distclean` too,
#    so we only fire it on fresh clones.
#
#  - SOURCE_DATE_EPOCH: mkreleasehdr.sh bakes `<hostname>-<epoch>` into
#    release.o unless SOURCE_DATE_EPOCH is set. Without pinning, every
#    build produces a different CA hash for the final binary.
#
# Env knobs:
#   REDIS_SRC   existing checkout (default: /tmp/redis-nixgg)
#   NIXGG_JOBS  -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
REDIS_SRC="${REDIS_SRC:-/tmp/redis-nixgg}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$REDIS_SRC" ]]; then
  printf '==> Cloning redis into %s\n' "$REDIS_SRC" >&2
  git clone --depth=1 https://github.com/redis/redis.git "$REDIS_SRC"
fi

# Redis's Makefile doesn't require pkg-config on our config (MALLOC=libc,
# no TLS). Plain `nixgg env` gives us gcc + make; that's enough.
eval "$("$here/bin/nixgg" env)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"
export NIXGG_AUTOFORCE=1

cd "$REDIS_SRC"

# Fresh-clone seed: initialise redis's settings-tracking file so make
# doesn't auto-trigger persist-settings (distclean) on every build.
if [[ ! -f src/.make-prerequisites ]]; then
  make -C src -j"$NIXGG_JOBS" MALLOC=libc persist-settings
fi

# Deps first (intermediate .a archives — link shim doesn't fire, so
# they stay as placeholder thunks that redis-server's link consumes).
make -C deps -j"$NIXGG_JOBS" \
  hiredis linenoise lua hdr_histogram fpconv xxhash tre

# Final link: shim sees the -o redis-server and realises the whole DAG.
cd src
exec make MALLOC=libc -j"$NIXGG_JOBS" redis-server
