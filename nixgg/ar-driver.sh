#!/usr/bin/env bash
# ar-driver.sh — bash replacement for driver.py's do_ar / do_ranlib.
#
# Called by the `ar` and `ranlib` shims. Argv0-dispatched.
#
# Behaviour matches driver.py:
#   - `ar <mod> <archive.a> <obj.o>…` with sidecars for every .o
#     → emit ar-thunk (placeholder mode) or realise the archive.
#   - Anything unrecognised or missing sidecars → passthrough to real ar/ranlib.
#   - `ranlib <archive.a>` where <archive.a> is a nixgg-managed symlink
#     → no-op (our archives are already indexed via `ar Dcru`).

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$_here/lib.sh"

TOOL="${1:?tool name required}"; shift
# @rspfile args are pre-expanded by shims/_dispatch.sh.

_passthrough_ar() {
  nixgg::emit "$(jq -cn --argjson argv "$(printf '%s\n' "$@" | jq -R . | jq -s .)" \
                       '{event: "ar", kind: "passthrough", argv: $argv}')"
  exec "$(nixgg::real_tool_for ar)" "$@"
}

_passthrough_ranlib() {
  exec "$(nixgg::real_tool_for ranlib)" "$@"
}

# ── ranlib: cheap check + delegate ──────────────────────────────────
# Archives we produce via `ar Dcru` already carry an index; if the
# target is a nixgg-managed symlink, ranlib is a no-op.
if [[ "$TOOL" == "ranlib" ]]; then
  if (( $# == 1 )) && [[ "$1" == *.a ]]; then
    read -r kind _ < <(nixgg::classify_target "$1")
    case "$kind" in
      store|thunk)
        nixgg::log "ranlib no-op: $1 was produced by nixgg"
        exit 0
        ;;
    esac
  fi
  _passthrough_ranlib "$@"
fi

# ── ar: parse args ──────────────────────────────────────────────────
[[ $# -ge 2 ]] || _passthrough_ar "$@"

first="$1"; shift
modifiers=""
case "$first" in
  -*) modifiers="${first:1}" ;;
  *)
    # Only accept the classic ar modifier chars.
    if [[ "$first" =~ ^[cruvsDxtpqR]+$ ]]; then modifiers="$first"; fi
    ;;
esac
[[ -z "$modifiers" ]] && _passthrough_ar "$first" "$@"
# Must include at least one of c/r/u/q (create/replace/update/quick).
[[ "$modifiers" =~ [cruq] ]] || _passthrough_ar "$first" "$@"

archive="$1"; shift
[[ "$archive" == *.a ]] || _passthrough_ar "-$modifiers" "$archive" "$@"
(( $# >= 1 )) || _passthrough_ar "-$modifiers" "$archive" "$@"
objects=("$@")
for o in "${objects[@]}"; do
  [[ "$o" == *.o ]] || _passthrough_ar "-$modifiers" "$archive" "${objects[@]}"
done

# ── ar: classify each object symlink ────────────────────────────────
# {ref_kind, ref, name}: ref_kind is "store" or "nix"; matches
# lib.sh:inputs_nix_from_json.
inputs_json='[]'
for o in "${objects[@]}"; do
  read -r kind ref < <(nixgg::classify_target "$o")
  case "$kind" in
    store|thunk) ;;
    *)
      nixgg::log "ar passthrough: $o isn't a nixgg symlink ($kind)"
      nixgg::emit "$(jq -cn --arg input "$o" \
                          --argjson argv "$(printf '%s\n' "-$modifiers" "$archive" "${objects[@]}" | jq -R . | jq -s .)" \
                          '{event: "ar", kind: "passthrough", reason: "missing_sidecar", input: $input, argv: $argv}')"
      exec "$(nixgg::real_tool_for ar)" "-$modifiers" "$archive" "${objects[@]}"
      ;;
  esac
  local_kind="$kind"; [[ "$kind" == thunk ]] && local_kind="nix"
  inputs_json=$(printf '%s' "$inputs_json" | jq -cS \
    --arg k "$local_kind" --arg r "$ref" --arg n "$(basename "$o")" \
    '. + [{ref_kind: $k, ref: $r, name: $n}]')
done

nixgg::log "archive $archive <- $(printf '%s ' "${objects[@]##*/}")"

# ── Build the thunk payload ────────────────────────────────────────
wrapper_env=$(nixgg::wrapper_env_json)
archive_basename=$(basename "$archive")

# Assemble the Nix expression once — used verbatim in either mode.
inputs_nix=$(nixgg::inputs_nix_from_json "$inputs_json")
store_deps_json=$(nixgg::store_deps_from '[]' "$wrapper_env")

expr=$(cat <<NIX
import $NIXGG_NIX_HELPERS/archiver.nix {
  outName        = "$archive_basename";
  inputs         = $inputs_nix;
  arFlags        = "$modifiers";
  storeDepsJSON  = ''$store_deps_json'';
  wrapperEnvJSON = ''$wrapper_env'';
}
NIX
)

# ── Placeholder mode: write .nix thunk, drop marker ─────────────
if [[ "$(nixgg::mode_for "$archive")" == "placeholder" ]]; then
  thunk_path=$(nixgg::write_thunk "$expr")
  nixgg::link_placeholder "$archive" "$thunk_path"
  nixgg::log "  thunk:  $thunk_path"
  nixgg::emit "$(jq -cn --arg archive "$archive" --argjson inputs "$inputs_json" \
                       --arg thunk "$thunk_path" \
                       '{event: "ar", kind: "thunk", archive: $archive, inputs: $inputs, thunk: $thunk}')"
  exit 0
fi

# Realise mode: any unrealised input → passthrough.
if echo "$inputs_json" | jq -e 'any(.ref_kind == "nix")' >/dev/null; then
  bad=$(echo "$inputs_json" | jq -r 'map(select(.ref_kind == "nix"))[0].name')
  nixgg::log "ar passthrough: input $bad is a thunk in realise mode"
  nixgg::emit "$(jq -cn --arg input "$bad" \
    '{event: "ar", kind: "passthrough", reason: "thunk_input_in_realise", input: $input}')"
  exec "$(nixgg::real_tool_for ar)" "-$modifiers" "$archive" "${objects[@]}"
fi

t0=$(date +%s.%N)
built=$(nixgg::nix_build_expr "$expr")
t1=$(date +%s.%N)

nixgg::log "  built: $built"
nixgg::link_store_to_output "$built" "$archive"
nixgg::emit_derivation ar archive "$archive" "$t0" "$t1" "$built" "$inputs_json"
