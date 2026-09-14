#!/usr/bin/env bash
# Verifies the literal --override-input cache "git+file://$PWD?ref=HEAD"
# workflow documented in the README actually works, for every example that
# has editable source. This is a different thing from `checks` in flake.nix:
# those exercise `withCache` (the library API); this exercises the CLI
# workflow a real user copy-pastes from the README.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EDIT_FILES=(c/main.c golang/main.go zig/main.zig rust/src/main.rs swift/Sources/swift-example/main.swift)

if ! git diff --quiet -- "${EDIT_FILES[@]}"; then
  echo "error: these files must be clean before running this script:" >&2
  git status --short -- "${EDIT_FILES[@]}" >&2
  exit 1
fi

failures=0
trap 'git checkout -- "${EDIT_FILES[@]}" 2>/dev/null; rm -f foo.db; rm -rf result*' EXIT

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "override-input-verify[$name]: OK (found \"$expected\")"
  else
    echo "override-input-verify[$name]: FAILED — expected \"$expected\" in output, got:" >&2
    echo "$actual" >&2
    failures=$((failures + 1))
  fi
}

# $1 name, $2 file, $3 old string, $4 new string (with MARKER placeholder),
# $5 relative path to the binary inside the built output
verify_edit() {
  local name="$1" file="$2" old="$3" new="$4" bin_rel_path="$5"
  local marker="MARK_${name}_$RANDOM"
  nix build ".#$name" -o "result-$name-cold"
  sed -i "s#${old}#${new//MARKER/$marker}#" "$file"
  nix build --override-input cache "git+file://$PWD?ref=HEAD" -L ".#$name" -o "result-$name-warm"
  local out
  out=$("./result-$name-warm/$bin_rel_path" 2>&1)
  check "$name" "$marker" "$out"
  git checkout -- "$file"
}

verify_edit c c/main.c \
  'printf("%d\\n", a_fn() + b_fn());' \
  'printf("MARKER %d\\n", a_fn() + b_fn());' \
  bin/c

verify_edit golang golang/main.go \
  'fmt.Println(id, name)' \
  'fmt.Println("MARKER", id, name)' \
  bin/ex

verify_edit zig zig/main.zig \
  'std.debug.print("Hello, world\\n", .{});' \
  'std.debug.print("MARKER\\n", .{});' \
  bin/hello

verify_edit rust rust/src/main.rs \
  'println!("hello from rust");' \
  'println!("MARKER");' \
  bin/rust-example

verify_edit swift swift/Sources/swift-example/main.swift \
  'print("hello from swift")' \
  'print("MARKER")' \
  bin/swift-example

# haskell (pandoc-cli, via mkIncrementalHaskellPackage) uses nixpkgs'
# own previousIntermediates mechanism, not ccache — there's no
# "ccache[name]: N/M hits" line to grep. Instead: force a real rebuild
# restoring from the same-source cache, and assert none of the
# package's own modules recompiled (only relinking is expected to run,
# since the object files came from the restored intermediates output).
# Setup.hs (cabal's own build driver, always rebuilt from scratch —
# it isn't part of `dist/build` and comes from nowhere but the fresh
# source tree) is excluded by matching its literal path in the
# GHC "Compiling X ( <path>, ..." line, not by module name — the
# real package's own entry point is also conventionally named `Main`.
verify_no_recompile() {
  local name="$1"
  nix build ".#$name" -o "result-$name-cold"
  local warm_drv
  warm_drv=$(nix path-info --derivation --override-input cache "git+file://$PWD?ref=HEAD" ".#$name")
  nix store delete "$warm_drv" $(nix-store -q --outputs "$warm_drv" 2>/dev/null) 2>/dev/null || true
  local log
  log=$(nix build --override-input cache "git+file://$PWD?ref=HEAD" -L ".#$name" -o "result-$name-warm" --builders "" 2>&1)
  if echo "$log" | grep -P '^\S+> \[\d+ of \d+\] Compiling' | grep -qv 'Setup\.hs'; then
    echo "override-input-verify[$name]: FAILED — expected no module recompiles, got:" >&2
    echo "$log" | grep -P '^\S+> \[\d+ of \d+\] Compiling' >&2
    failures=$((failures + 1))
  else
    echo "override-input-verify[$name]: OK (no module recompiles restoring from same-source cache)"
  fi
}

verify_no_recompile haskell

# hello-ccache wraps pkgs.hello unchanged, so its derivation is
# byte-identical run to run and Nix would otherwise substitute instead of
# rebuilding, skipping the ccache report entirely. Force a real rebuild by
# deleting any already-valid output for the exact (cache-overridden)
# derivation first, and disabling remote builders for this one build — a
# configured remote builder can still have (and hand back) the same
# output even after it's deleted locally.
verify_ccache_hits() {
  local name="$1"
  nix build ".#$name" -o "result-$name-cold"
  local warm_drv
  warm_drv=$(nix path-info --derivation --override-input cache "git+file://$PWD?ref=HEAD" ".#$name")
  nix store delete "$warm_drv" $(nix-store -q --outputs "$warm_drv" 2>/dev/null) 2>/dev/null || true
  local log
  log=$(nix build --override-input cache "git+file://$PWD?ref=HEAD" -L ".#$name" -o "result-$name-warm" --builders "" 2>&1)
  local hits
  hits=$(echo "$log" | grep -oP "ccache\[$name\]: \K[0-9]+(?=/[0-9]+ hits)" | tail -1)
  if [ "${hits:-0}" -gt 0 ]; then
    echo "override-input-verify[$name]: OK ($hits ccache hits)"
  else
    echo "override-input-verify[$name]: FAILED — expected a nonzero ccache hit count, got:" >&2
    echo "$log" >&2
    failures=$((failures + 1))
  fi
}

verify_ccache_hits hello-ccache

# nixpkgs-jq/nixpkgs-redis/nixpkgs-tmux/nixpkgs-python3/nixpkgs-perl
# check the same mechanism (a shallow vs. recursive nuke-refs bug
# regressed exactly this — see git history) against real, sizable
# nixpkgs packages instead of this repo's own toy examples.
# nixpkgs-llvm and nixpkgs-opencv (see nixpkgs-examples.nix) are
# deliberately excluded here: cold builds took 35+ and ~27 minutes
# respectively on 22 cores locally, and ubuntu-latest CI runners have
# far fewer — verified locally instead, not on every push/PR.
verify_ccache_hits nixpkgs-jq
verify_ccache_hits nixpkgs-redis
verify_ccache_hits nixpkgs-tmux
verify_ccache_hits nixpkgs-python3
verify_ccache_hits nixpkgs-perl
verify_ccache_hits nixpkgs-fmt
verify_ccache_hits nixpkgs-protobuf

# Everything above restores from a same-source build — it proves the
# restore/nuke-refs mechanism doesn't have false negatives, but not
# that a real code change only invalidates what it touches. Each
# "-patched" package applies one small, real upstream commit (see
# patches/) on top of the unpatched one — same cache key
# (mkNixpkgsExample's name is the unpatched attr name, e.g. "nixpkgs-jq"
# for both nixpkgs-jq and nixpkgs-jq-patched), so restoring from the
# unpatched build's cache and building the patched one exercises a
# genuine single-file diff. Expect high but non-100% hits: only the
# patched file (and anything that depends on it) should miss.
# nixpkgs-llvm-patched and nixpkgs-opencv-patched are excluded from CI
# for the same reason as their unpatched packages above.
verify_patch_incrementality() {
  local base="$1" patched="$2"
  nix build ".#$base" -o "result-$base-cold"
  local warm_drv
  warm_drv=$(nix path-info --derivation --override-input cache "git+file://$PWD?ref=HEAD" ".#$patched")
  nix store delete "$warm_drv" $(nix-store -q --outputs "$warm_drv" 2>/dev/null) 2>/dev/null || true
  local log
  log=$(nix build --override-input cache "git+file://$PWD?ref=HEAD" -L ".#$patched" -o "result-$patched-warm" --builders "" 2>&1)
  local hits
  hits=$(echo "$log" | grep -oP "ccache\[$base\]: \K[0-9]+(?=/[0-9]+ hits)" | tail -1)
  if [ "${hits:-0}" -gt 0 ]; then
    echo "override-input-verify[$patched]: OK ($hits ccache hits restoring from unpatched $base)"
  else
    echo "override-input-verify[$patched]: FAILED — expected a nonzero ccache hit count, got:" >&2
    echo "$log" >&2
    failures=$((failures + 1))
  fi
}

verify_patch_incrementality nixpkgs-jq nixpkgs-jq-patched
verify_patch_incrementality nixpkgs-redis nixpkgs-redis-patched
verify_patch_incrementality nixpkgs-tmux nixpkgs-tmux-patched
verify_patch_incrementality nixpkgs-python3 nixpkgs-python3-patched
verify_patch_incrementality nixpkgs-perl nixpkgs-perl-patched
verify_patch_incrementality nixpkgs-fmt nixpkgs-fmt-patched
verify_patch_incrementality nixpkgs-protobuf nixpkgs-protobuf-patched

if [ "$failures" -gt 0 ]; then
  echo "override-input-verify: $failures check(s) failed" >&2
  exit 1
fi
echo "override-input-verify: all checks passed"
