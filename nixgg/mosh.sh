#!/usr/bin/env bash
# Point nixgg at mosh's build. Runs autogen + configure + make with our
# shims in front of PATH. Toolchain + system deps come from the flake,
# so this script has no OS package requirements beyond `nix`.
#
# Env knobs:
#   MOSH_SRC          existing checkout to build (default: clone under /tmp)
#   NIXGG_JOBS        -j level for make (default: nproc)
#   NIXGG_MODE        realise (default) or placeholder
#   NIXGG_STAGE_ONLY  set to 1 to skip build and drop into an
#                     interactive `nix develop` shell instead

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
MOSH_SRC="${MOSH_SRC:-/tmp/nixgg-mosh/mosh}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
[[ -x "$BOOTSTRAP_NIX" ]] || fail "no nix on PATH"

if [[ ! -d "$MOSH_SRC" ]]; then
  info "Cloning mosh into $MOSH_SRC"
  mkdir -p "$(dirname "$MOSH_SRC")"
  git clone --depth=1 https://github.com/mobile-shell/mosh.git "$MOSH_SRC"
fi

# Optional: drop into the mosh build env for hacking.
if [[ "${NIXGG_STAGE_ONLY:-0}" == "1" ]]; then
  info "NIXGG_STAGE_ONLY=1 — dropping into nix develop .#mosh-env"
  exec "$BOOTSTRAP_NIX" develop "$here#mosh-env"
fi

# Everything else runs inside `nix develop .#mosh-env` so autoconf,
# protoc, and pkg-config are on PATH with correct NIX_CFLAGS_COMPILE
# etc. nixgg auto-bootstraps its own toolchain vars — no manual env
# plumbing needed.
export MOSH_SRC NIXGG_JOBS
INNER_SCRIPT='
set -euo pipefail
cd "$MOSH_SRC"
if [[ ! -x configure ]]; then
  ./autogen.sh 2>&1 | tail -5 || true
fi
# Configure must run its probes for real → always realise mode.
if [[ ! -f Makefile ]]; then
  "'"$here"'/nixgg" run -- ./configure --disable-hardening 2>&1 | tail -3
fi

if [[ "${NIXGG_MODE:-realise}" == placeholder ]]; then
  "'"$here"'/nixgg" build \
    --target src/frontend/mosh-client \
    --target src/frontend/mosh-server \
    -- make -j"$NIXGG_JOBS"
else
  "'"$here"'/nixgg" run -- make -j"$NIXGG_JOBS"
fi
'

exec "$BOOTSTRAP_NIX" develop "$here#mosh-env" --command bash -c "$INNER_SCRIPT"
