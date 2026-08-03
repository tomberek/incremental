#!/usr/bin/env bash
# Regression test: native and sandbox modes must produce byte-identical
# .drv files for the same source.
#
# Fixture is nixgg/example/ — a two-TU project (main.cc + util.cc)
# with a Makefile. Both:
#
#   native:   `nix develop . -c make` in example/ (writes .nix thunks,
#             then nix-instantiate → drv path)
#   sandbox:  `nix build .#hello`      (nix derivation add via
#             builder-rpc-v0 daemon RPC)
#
# should hit the same three drv paths: tu-main.o, tu-util.o, bin-hello.
# If they diverge, one code path drifted; check the recent commits
# touching internal/expr/, internal/shim/compile.go, or
# internal/shim/link.go.
#
# Env knobs:
#   ALT_STORE   root of the alternate store (default /tmp/nixgg-equiv-store)
#   PATCHED_NIX explicit path to a nix built from PR-15793-era master
#               (default: /home/…/builder-rpc-v0/patched-nix)
#   KEEP_STORE  set to 1 to skip wiping ALT_STORE at start

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
nixgg_root="$(cd "$here/.." && pwd)"

ALT_STORE="${ALT_STORE:-/tmp/nixgg-equiv-store}"
PATCHED_NIX="${PATCHED_NIX:-$nixgg_root/../builder-rpc-v0/patched-nix}"

if [[ ! -x "$PATCHED_NIX/bin/nix" ]]; then
  echo "PATCHED_NIX/bin/nix not found: $PATCHED_NIX" >&2
  echo "Build via: nix build $nixgg_root#patched-nix -o $nixgg_root/../builder-rpc-v0/patched-nix" >&2
  exit 2
fi

# ---------- 1. clean alt store ----------
if [[ "${KEEP_STORE:-}" != "1" ]]; then
  chmod -R u+w "$ALT_STORE" 2>/dev/null || true
  rm -rf "$ALT_STORE"
fi
mkdir -p "$ALT_STORE"

export NIX_REMOTE=""
export NIX_CONFIG="
experimental-features = nix-command flakes ca-derivations dynamic-derivations configurable-impure-env
extra-system-features = builder-rpc-v0
store = local?root=$ALT_STORE
"

# Seed the alt store with patched-nix (it's the builder for the outer
# `.drv.drv` derivation, so needs to be reachable).
if [[ ! -e "$ALT_STORE/$(readlink -f "$PATCHED_NIX" | sed s,^/nix/store,/nix/store,)" ]]; then
  "$PATCHED_NIX/bin/nix" copy --from daemon --to "local?root=$ALT_STORE" \
      --no-check-sigs "$(readlink -f "$PATCHED_NIX")" >/dev/null 2>&1 || true
fi

# ---------- 2. sandbox build via .#hello ----------
printf '==> sandbox: nix build .#hello\n'
"$PATCHED_NIX/bin/nix" build --no-eval-cache --no-link \
  --print-out-paths "$nixgg_root#hello" >/dev/null 2>&1

# Strip the alt-store prefix so the reported paths match native's
# canonical `/nix/store/…` form — the CA hash is what matters, not
# where on disk the file lives.
strip_prefix() { echo "${1#$ALT_STORE}"; }

sb_main=$(strip_prefix "$(ls "$ALT_STORE"/nix/store/*tu-main.o.drv 2>/dev/null | head -1)")
sb_util=$(strip_prefix "$(ls "$ALT_STORE"/nix/store/*tu-util.o.drv 2>/dev/null | head -1)")
# Two bin-hello.drv exist per successful build: one with drv inputs
# (dyn-drv, unresolved) and one after resolution. The unresolved form
# is what `nix-instantiate` on native's link thunk produces.
sb_link=$(strip_prefix "$(ls "$ALT_STORE"/nix/store/*bin-hello.drv 2>/dev/null | grep -v '\.drv\.drv$' | sort | head -1)")

printf '   sandbox drvs:\n'
printf '     main:  %s\n' "$sb_main"
printf '     util:  %s\n' "$sb_util"
printf '     link:  %s\n' "$sb_link"

# ---------- 3. native build via `make` in example/ ----------
printf '==> native: nix develop -c make in example/\n'
# Any preexisting .nixgg/ upstream of example/ is what auto-seed
# picks; wipe both possible locations.
rm -rf "$nixgg_root/../.nixgg" "$nixgg_root/example/.nixgg" \
       "$nixgg_root/example/main.o" "$nixgg_root/example/util.o" \
       "$nixgg_root/example/hello" 2>/dev/null || true

(
  cd "$nixgg_root/example"
  # Use the flake's dev shell explicitly rather than the ambient one;
  # ensures we pick up the same nixgg binary the flake ships.
  nix develop "$nixgg_root" --command bash -c "
    export NIXGG_STORE='local?root=$ALT_STORE'
    export NIXGG_AUTOFORCE=0
    make >/dev/null
  "
) 2>&1 | grep -E '^\[nixgg\]|error' || true

# The auto-seed picks the repo git root, which lives one dir above
# nixgg/ — so thunks may land at ../../.nixgg/thunks. Search both.
thunks_dir=""
for candidate in \
    "$nixgg_root/../.nixgg/thunks" \
    "$nixgg_root/example/.nixgg/thunks"; do
  if compgen -G "$candidate/*.nix" > /dev/null; then
    thunks_dir="$candidate"
    break
  fi
done
if [[ -z "$thunks_dir" ]]; then
  echo "native build produced no thunks; something is wrong" >&2
  exit 3
fi

# nix-instantiate each thunk → its drv path. We identify main/util by
# grepping the thunk's outName; link is the one that imports the two.
nt_main=""; nt_util=""; nt_link=""
for t in "$thunks_dir"/*.nix; do
  out_name=$(grep -oE 'outName +=[^;]*' "$t" | head -1 | tr -d '\"' | awk -F= '{print $2}' | tr -d ' ')
  drv=$("$PATCHED_NIX/bin/nix" eval --no-eval-cache --impure --raw --file "$t" drvPath 2>/dev/null)
  case "$out_name" in
    main.o) nt_main="$drv" ;;
    util.o) nt_util="$drv" ;;
    hello)  nt_link="$drv" ;;
  esac
done

printf '   native drvs:\n'
printf '     main:  %s\n' "$nt_main"
printf '     util:  %s\n' "$nt_util"
printf '     link:  %s\n' "$nt_link"

# ---------- 4. compare ----------
fail=0
compare() {
  local label="$1" sandbox="$2" native="$3"
  if [[ "$sandbox" != "$native" ]]; then
    printf '\033[1;31mMISMATCH\033[0m %s\n' "$label" >&2
    printf '  sandbox: %s\n' "$sandbox" >&2
    printf '  native:  %s\n' "$native"  >&2
    fail=1
  else
    printf '\033[1;32mMATCH\033[0m    %s   %s\n' "$label" "$sandbox"
  fi
}

echo
compare "main.o" "$sb_main" "$nt_main"
compare "util.o" "$sb_util" "$nt_util"
compare "hello"  "$sb_link" "$nt_link"

if (( fail )); then
  exit 1
fi
echo
echo "all drvs byte-identical between native and sandbox."
