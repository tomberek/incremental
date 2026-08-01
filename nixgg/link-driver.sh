#!/usr/bin/env bash
# link-driver.sh — bash replacement for driver.py's do_link.
#
# Called by cc/gcc/c++/g++ shims when there's no `-c` on argv.
# Modelled after ar-driver.sh: parse argv, resolve every .o/.a input's
# sidecar, either write a link thunk (placeholder mode) or realise the
# link derivation via nix build (realise mode). Passthrough for anything
# unrecognised or with missing sidecars.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$_here/lib.sh"

# argv0 conventionally identifies the tool; the shim passes it as $1.
TOOL="${1:?tool name required}"; shift
# @rspfile args are pre-expanded by shims/_dispatch.sh.

_argv_json() {
  printf '%s\n' "$@" | jq -R . | jq -s .
}

_passthrough() {
  local reason="${1:-}"
  if [[ -n "$reason" ]]; then shift; fi
  local extra=""
  case "$reason" in
    argv)
      nixgg::emit "$(jq -cn --argjson argv "$(_argv_json "$@")" \
        '{event: "link", kind: "passthrough", argv: $argv}')"
      ;;
    missing_sidecar)
      local input="$1"; shift
      nixgg::emit "$(jq -cn --arg input "$input" \
                           --argjson argv "$(_argv_json "$@")" \
        '{event: "link", kind: "passthrough", reason: "missing_sidecar", input: $input, argv: $argv}')"
      ;;
    thunk_input_in_realise)
      local input="$1"; shift
      nixgg::emit "$(jq -cn --arg input "$input" \
        '{event: "link", kind: "passthrough", reason: "thunk_input_in_realise", input: $input}')"
      ;;
    "")
      # Just passthrough with no emit.
      :
      ;;
  esac
  exec "$NIXGG_REAL_CC" "$@"
}

# Refuse to model these — they're compile-family invocations.
for a in "$@"; do
  case "$a" in
    -c|-E|-S|-M|-MM)
      nixgg::log "passthrough (not a link we understand): $*"
      _passthrough argv "$@"
      ;;
  esac
done

# ── Parse argv: extract -o OUTPUT + .o/.a inputs, everything else = flags ─
output=""
inputs=()
flags=()
i=0
argv=("$@")
n=${#argv[@]}
while (( i < n )); do
  a="${argv[i]}"
  case "$a" in
    -o)      output="${argv[i+1]}"; i=$((i+2)); continue ;;
    -o?*)    output="${a:2}"; i=$((i+1)); continue ;;
    *.o|*.a) inputs+=( "$a" ); i=$((i+1)); continue ;;
    # Drop dep-file flags — they target host paths, not our sandbox.
    -M|-MM|-MG|-MP|-MD|-MMD) i=$((i+1)); continue ;;
    -MF|-MT|-MQ)             i=$((i+2)); continue ;;
    *)       flags+=( "$a" );  i=$((i+1)); continue ;;
  esac
done
if (( ${#inputs[@]} == 0 )) || [[ -z "$output" ]]; then
  nixgg::log "passthrough (not a link we understand): $*"
  _passthrough argv "$@"
fi

# ── Classify every input by inspecting the symlink ───────────────
# `nixgg::classify_target` reads the target's own symlink shape:
#   store <path>   → target → /nix/store/…  (realised earlier)
#   thunk <path>   → target → …/thunks/<id>.nix (unrealised)
#   regular|absent → nixgg doesn't own this input → passthrough
inputs_json='[]'
for inp in "${inputs[@]}"; do
  read -r kind ref < <(nixgg::classify_target "$inp")
  case "$kind" in
    store|thunk) ;;
    *)
      nixgg::log "link passthrough: $inp isn't a nixgg symlink ($kind)"
      _passthrough missing_sidecar "$inp" "$@"
      ;;
  esac
  # ref_kind in the payload matches lib.sh:inputs_nix_from_json:
  #   "store" → wrap with `builtins.storePath` in the Nix expr
  #   "nix"   → `import` the thunk file
  local_kind="$kind"; [[ "$kind" == thunk ]] && local_kind="nix"
  inputs_json=$(printf '%s' "$inputs_json" | jq -cS \
    --arg k "$local_kind" --arg r "$ref" --arg n "$(basename "$inp")" \
    '. + [{ref_kind: $k, ref: $r, name: $n}]')
done

nixgg::log "link $output <- $(printf '%s ' "${inputs[@]##*/}")"

# ── Build the thunk payload ───────────────────────────────────────
wrapper_env=$(nixgg::wrapper_env_json)
out_basename=$(basename "$output")
if (( ${#flags[@]} == 0 )); then
  flags_json='[]'
else
  flags_json=$(printf '%s\n' "${flags[@]}" | jq -R . | jq -s .)
fi
tool_basename=$(basename "$NIXGG_REAL_CC")

# Assemble the Nix expression once — used verbatim in either mode.
# Inputs are wrapped either as `builtins.storePath "…"` (already
# realised) or `import "/path/to/thunk.nix"` (unrealised sibling).
inputs_nix=$(nixgg::inputs_nix_from_json "$inputs_json")
store_deps_json=$(nixgg::store_deps_from "$flags_json" "$wrapper_env")

expr=$(cat <<NIX
import $NIXGG_NIX_HELPERS/linker.nix {
  compilerRoot   = "$NIXGG_COMPILER_ROOT";
  toolBasename   = "$tool_basename";
  bashRoot       = "$NIXGG_BASH_ROOT";
  coreutilsRoot  = "$NIXGG_COREUTILS_ROOT";
  outName        = "$out_basename";
  inputs         = $inputs_nix;
  flagsJSON      = ''$flags_json'';
  storeDepsJSON  = ''$store_deps_json'';
  wrapperEnvJSON = ''$wrapper_env'';
}
NIX
)

# ── Placeholder mode: write .nix thunk, drop marker ─────────────
if [[ "$(nixgg::mode_for "$output")" == "placeholder" ]]; then
  thunk_path=$(nixgg::write_thunk "$expr")
  nixgg::link_placeholder "$output" "$thunk_path"
  nixgg::log "  thunk:  $thunk_path"
  nixgg::emit "$(jq -cn --arg output "$output" --argjson inputs "$inputs_json" \
                       --arg thunk "$thunk_path" \
                       '{event: "link", kind: "thunk", output: $output, inputs: $inputs, thunk: $thunk}')"
  exit 0
fi

# Realise mode: any unrealised input → passthrough (can't build the
# whole graph inline; force it later).
if echo "$inputs_json" | jq -e 'any(.ref_kind == "nix")' >/dev/null; then
  bad=$(echo "$inputs_json" | jq -r 'map(select(.ref_kind == "nix"))[0].name')
  nixgg::log "link passthrough: input $bad is a thunk in realise mode"
  _passthrough thunk_input_in_realise "$bad" "$@"
fi

t0=$(date +%s.%N)
built=$(nixgg::nix_build_expr "$expr")
t1=$(date +%s.%N)

nixgg::log "  built: $built"
nixgg::link_store_to_output "$built" "$output"
nixgg::emit_derivation link output "$output" "$t0" "$t1" "$built" "$inputs_json"
