#!/usr/bin/env bash
# Build the toy example via nixgg — auto-bootstraps the toolchain.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
nixgg_root="$(cd "$here/.." && pwd)"

cd "$here"
rm -f ./*.o hello
rm -rf .nixgg

"$nixgg_root/nixgg" build --target hello -- make -j"${JOBS:-2}"

./hello
