#!/usr/bin/env bash
# Verifies the literal --override-input cache "git+file://$PWD?ref=HEAD"
# workflow documented in the README actually works, for every example that
# has editable source. This is a different thing from `checks` in flake.nix:
# those exercise `withCache` (the library API); this exercises the CLI
# workflow a real user copy-pastes from the README.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

EDIT_FILES=(c/main.c golang/main.go zig/main.zig rust/src/main.rs)

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

# hello-ccache wraps pkgs.hello unchanged, so its derivation is
# byte-identical run to run and Nix would otherwise substitute instead of
# rebuilding, skipping the ccache report entirely. Force a real rebuild by
# deleting any already-valid output for the exact (cache-overridden)
# derivation first — more portable than relying on --rebuild's own
# double-build-and-diff behavior, which needs a prior valid build present
# and behaves differently depending on what builders/substituters are
# configured.
nix build .#hello-ccache -o result-hello-ccache-cold
warm_drv=$(nix path-info --derivation --override-input cache "git+file://$PWD?ref=HEAD" .#hello-ccache)
nix store delete "$warm_drv" $(nix-store -q --outputs "$warm_drv" 2>/dev/null) 2>/dev/null || true
log=$(nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#hello-ccache -o result-hello-ccache-warm 2>&1)
hits=$(echo "$log" | grep -oP 'ccache\[hello-ccache\]: \K[0-9]+(?=/[0-9]+ hits)' || echo 0)
if [ "${hits:-0}" -gt 0 ]; then
  echo "override-input-verify[hello-ccache]: OK ($hits ccache hits)"
else
  echo "override-input-verify[hello-ccache]: FAILED — expected a nonzero ccache hit count, got:" >&2
  echo "$log" >&2
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "override-input-verify: $failures check(s) failed" >&2
  exit 1
fi
echo "override-input-verify: all checks passed"
