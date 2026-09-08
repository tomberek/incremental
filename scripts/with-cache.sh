#!/usr/bin/env bash
# Builds a third party's flake output restoring from a baseline build,
# with no --override-input and no edits to the target's flake.nix —
# just passthru.withCache, which every mkIncrementalPackage-based
# derivation carries. Unlike --override-input cache (build-with-cache.sh,
# build-input-diff.sh), baseline and target can be entirely different
# flakes.
#
# usage: with-cache.sh <baseline-flake-ref> [target-flake-ref#name-or-attrpath] [nix build args...]
#
# target defaults to ".#default", matching `nix build`'s own default.
#
# Example: seed from a previous local build, then build after an edit —
#   with-cache.sh .
#
# <name-or-attrpath> with no dots expands to packages.<system>.<name>,
# matching `nix build`'s own shorthand; a dotted path (e.g.
# checks.x86_64-linux.foo) is used as given.
#
# baseline is auto-pinned to its locked rev via `nix flake metadata`
# if it isn't already — withCache requires a rev-pinned ref since
# builtins.getFlake only resolves locked refs under pure eval.
set -euo pipefail

self="$(basename "$0")"
if [ "$#" -lt 1 ]; then
  echo "usage: $self <baseline-flake-ref> [target-flake-ref#name-or-attrpath] [nix build args...]" >&2
  exit 1
fi

baseline="$1"
shift
target=".#default"
if [ "$#" -gt 0 ] && [[ "$1" == *#* ]]; then
  target="$1"
  shift
fi

flake_ref="${target%%#*}"
attr_path_str="${target#*#}"

case "$attr_path_str" in
*.*) ;; # already a full attrpath, e.g. checks.x86_64-linux.foo
*)
  system=$(nix eval --impure --raw --expr builtins.currentSystem)
  attr_path_str="packages.$system.$attr_path_str"
  ;;
esac

# getFlake needs an absolute flake ref (e.g. "." isn't accepted) even
# under --impure for a dirty/unlocked tree — resolvedUrl gives that
# without requiring a locked rev, unlike .url.
flake_ref="$(nix flake metadata --json "$flake_ref" | jq -r .resolvedUrl)"
baseline_locked="$(nix flake metadata --json "$baseline" | jq -r .url)"

IFS='.' read -r -a parts <<<"$attr_path_str"
nix_list="["
for p in "${parts[@]}"; do nix_list+=" \"$p\""; done
nix_list+=" ]"
expr="let pkg = builtins.foldl' (acc: a: acc.\${a}) (builtins.getFlake \"$flake_ref\") $nix_list; in pkg.withCache \"$baseline_locked\""

echo "==> building $target restoring from baseline ($baseline_locked)" >&2
nix build --impure --expr "$expr" "$@" -L
