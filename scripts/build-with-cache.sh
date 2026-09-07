#!/usr/bin/env bash
# Builds a "base" installable first, then builds a "target" installable
# restoring from base's incremental output via --override-input cache.
# Any --override-input used for base is mirrored onto cache/<name> for
# target, so target's `cache` is evaluated with the exact same inputs
# base was actually built with, not a guess.
#
# usage: build-with-cache.sh <base-installable> [nix build args...] \
#                          -- <target-installable> [nix build args...]
#
# Example: seed a cache from master, then build a PR against it —
#   build-with-cache.sh \
#     ".#nix-incremental" --override-input nix github:NixOS/nix/master \
#     -- \
#     ".#nix-incremental" --override-input nix github:NixOS/nix/pull/16428/merge
set -euo pipefail

self="$(basename "$0")"
base_args=()
target_args=()
in_target=0
for arg in "$@"; do
  if [ "$in_target" = 0 ] && [ "$arg" = "--" ]; then
    in_target=1
    continue
  fi
  if [ "$in_target" = 0 ]; then
    base_args+=("$arg")
  else
    target_args+=("$arg")
  fi
done

if [ "${#base_args[@]}" -lt 1 ] || [ "${#target_args[@]}" -lt 1 ]; then
  echo "usage: $self <base-installable> [nix build args...] -- <target-installable> [nix build args...]" >&2
  exit 1
fi

base_flake_ref="${base_args[0]%%#*}"

echo "==> building base: ${base_args[*]}" >&2
nix build "${base_args[@]}" -L

# Mirror base's --override-input flags onto cache/<name> for target, so
# target's `cache` resolves with the exact inputs base was built with.
cache_overrides=(--override-input cache "$base_flake_ref")
i=0
while [ "$i" -lt "${#base_args[@]}" ]; do
  if [ "${base_args[$i]}" = "--override-input" ]; then
    name="${base_args[$((i + 1))]}"
    value="${base_args[$((i + 2))]}"
    cache_overrides+=(--override-input "cache/$name" "$value")
    i=$((i + 3))
  else
    i=$((i + 1))
  fi
done

echo "==> building target: ${target_args[*]} ${cache_overrides[*]}" >&2
nix build "${target_args[@]}" "${cache_overrides[@]}" -L
