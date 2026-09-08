#!/usr/bin/env bash
# Specialized build-with-cache.sh for the single most common case:
# comparing two revs of one flake input (e.g. a NixOS/nix PR against
# master) for the same installable, so the target build reuses the
# base build's cache.
#
# usage: build-input-diff.sh <installable> <input-name> <base-ref> <target-ref> [nix build args...]
#
# Example: seed a cache from master, then build PR #16432 against it —
#   build-input-diff.sh .#nix-all-components nix github:NixOS/nix/master github:NixOS/nix/pull/16432/merge
set -euo pipefail

self="$(basename "$0")"
if [ "$#" -lt 4 ]; then
  echo "usage: $self <installable> <input-name> <base-ref> <target-ref> [nix build args...]" >&2
  exit 1
fi

installable="$1"
input_name="$2"
base_ref="$3"
target_ref="$4"
shift 4

flake_ref="${installable%%#*}"

echo "==> building base ($input_name = $base_ref): $installable" >&2
nix build "$installable" --override-input "$input_name" "$base_ref" "$@" -L

echo "==> building target ($input_name = $target_ref): $installable, restoring from base" >&2
nix build "$installable" --override-input "$input_name" "$target_ref" \
  --override-input cache "$flake_ref" \
  --override-input "cache/$input_name" "$base_ref" \
  "$@" -L
