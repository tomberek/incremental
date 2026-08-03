#!/usr/bin/env bash
# Build mosh through nixgg. Mosh has autoconf + protoc + pkg-config,
# so we layer the flake's mosh-env dev shell on top of `nixgg env`.
#
# The configure phase MUST run in realise mode: autoconf conftests
# compile little .c files and immediately `./conftest`, which requires
# a runnable binary. The compile shim recognises conftest* filenames
# and realises synchronously (see mode.For).
#
# Env knobs:
#   MOSH_SRC    existing checkout (default: /tmp/mosh-nixgg)
#   NIXGG_JOBS  -j level (default: nproc)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
MOSH_SRC="${MOSH_SRC:-/tmp/mosh-nixgg}"
NIXGG_JOBS="${NIXGG_JOBS:-$(nproc)}"

if [[ ! -d "$MOSH_SRC" ]]; then
  printf '==> Cloning mosh into %s\n' "$MOSH_SRC" >&2
  git clone --depth=1 https://github.com/mobile-shell/mosh.git "$MOSH_SRC"
fi

# We can't just `eval $(nixgg env)` — mosh needs autoconf/automake/
# libtool/protoc/pkg-config, which live in the mosh-env dev shell.
# So we run everything under `nix develop .#mosh-env` and set up nixgg
# by sourcing env-shell + prepending shims to whatever PATH mosh-env
# gives us.
BOOTSTRAP_NIX="${BOOTSTRAP_NIX:-$(command -v nix)}"
NIXGG_ENV_SHELL=$("$BOOTSTRAP_NIX" build "$here#env-shell" --no-link --print-out-paths)
export NIXGG_STORE="${NIXGG_STORE:-local?root=/tmp/nixgg-store}"

exec "$BOOTSTRAP_NIX" develop "$here#mosh-env" --command bash -c '
  set -euo pipefail
  set -a
  . "'"$NIXGG_ENV_SHELL"'"
  set +a
  export PATH="'"$here"'/bin:'"$here"'/shims:$PATH"
  export NIXGG_ROOT="'"$here"'"
  export CC=cc CXX=c++

  cd "'"$MOSH_SRC"'"
  [[ -x configure ]] || ./autogen.sh 2>/dev/null || true

  # Configure runs autoconf conftests, which compile + immediately exec
  # small test programs. Compile shim recognises conftest* filenames
  # and realises those TUs synchronously (see mode.For), so autoconf
  # sees real .o files. Not placeholder-mode.
  [[ -f Makefile ]] || ./configure --disable-hardening

  # Build: placeholder compile/archive, link shim auto-forces.
  export NIXGG_AUTOFORCE=1
  make -j'"$NIXGG_JOBS"'
'
