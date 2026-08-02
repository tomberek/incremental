#!/usr/bin/env bash
# compile-driver.sh — bash replacement for driver.py's do_compile.
#
# Called by cc/gcc/c++/g++ shims when `-c` is present. Same behaviour
# as the retired Python compile driver:
#
#   1. Parse argv into {source, output, flags, include_dirs, forced_includes}.
#   2. Call scan-headers.sh to enumerate user headers + project root.
#   3. Stage source + headers into a tmp dir preserving project-root-rel
#      paths, then `nix store add`.
#   4. Rewrite flags: strip caller -I/-isystem/-iquote/-idirafter/-include,
#      re-add sandbox-relative -I flags from scan-headers, keep store -I
#      flags verbatim.
#   5. Build the payload JSON. In placeholder mode write thunk +
#      placeholder + sidecar. In realise mode instantiate the CA
#      derivation via `nix build`, copy .o back, write sidecar.

set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$_here/lib.sh"

TOOL="${1:?tool name required}"; shift
# @rspfile args are pre-expanded by shims/_dispatch.sh.

_argv_json() {
  if (( $# == 0 )); then printf '[]'; else printf '%s\n' "$@" | jq -R . | jq -s .; fi
}

_passthrough() {
  # Args: <reason> [<argv…>]  or just <argv…> if no reason to emit.
  local reason="${1:-}"
  if [[ -n "$reason" && "$reason" == compile_* ]]; then shift; fi
  nixgg::emit "$(jq -cn --arg tool "$TOOL" --argjson argv "$(_argv_json "$@")" \
    '{event: "compile", kind: "passthrough", tool: $tool, argv: $argv}')"
  exec "$NIXGG_REAL_CC" "$@"
}

# ── 1. Parse argv ─────────────────────────────────────────────────
# Only handles single-TU `-c` invocations. Anything else → passthrough.

# 2-arg flags whose value we care about for header search.
_is_path_flag() {
  case "$1" in
    -I|-isystem|-iquote|-idirafter|-include) return 0 ;;
    *) return 1 ;;
  esac
}

has_c=0
source=""
output=""
include_dirs=()
forced_includes=()
passthrough=()
argv=("$@")
n=${#argv[@]}
i=0
while (( i < n )); do
  a="${argv[i]}"
  case "$a" in
    -c)
      has_c=1
      i=$((i+1))
      continue
      ;;
    -o)
      output="${argv[i+1]}"; i=$((i+2)); continue ;;
    -o?*)
      output="${a:2}"; i=$((i+1)); continue ;;
    -I?*)
      include_dirs+=( "${a:2}" )
      passthrough+=( "$a" )
      i=$((i+1)); continue
      ;;
    -I|-isystem|-iquote|-idirafter|-include)
      val="${argv[i+1]}"
      if [[ "$a" == "-include" ]]; then
        forced_includes+=( "$val" )
      else
        include_dirs+=( "$val" )
      fi
      passthrough+=( "$a" "$val" )
      i=$((i+2)); continue
      ;;
    # Dep-file generation flags — drop them. They target paths outside
    # our sandbox, and scan-headers.sh already produced the header list
    # we need. Includes both 1-arg (-M -MM -MG -MP -MD -MMD) and 2-arg
    # (-MF -MT -MQ <arg>) forms.
    -M|-MM|-MG|-MP|-MD|-MMD)
      i=$((i+1)); continue ;;
    -MF|-MT|-MQ)
      i=$((i+2)); continue ;;
    *.c|*.cc|*.cpp|*.cxx|*.C|*.S|*.s)
      if [[ -n "$source" ]]; then
        # Multiple sources — give up on modelling.
        nixgg::log "passthrough (multiple sources): $TOOL $*"
        _passthrough compile_multi "$@"
      fi
      source="$a"
      i=$((i+1)); continue
      ;;
    *)
      passthrough+=( "$a" )
      i=$((i+1)); continue
      ;;
  esac
done

if (( has_c == 0 )) || [[ -z "$source" ]]; then
  nixgg::log "passthrough (not a single-TU compile): $TOOL $*"
  _passthrough compile_not_tu "$@"
fi

if [[ -z "$output" ]]; then
  # gcc default is to name the object after the source in cwd.
  base=$(basename "$source")
  output="${base%.*}.o"
fi

# ── Argv-keyed short-circuit ───────────────────────────────────────
# The fast path for warm rebuilds: hash the whole compile invocation
# (tool + full argv + output basename), look up whether we've done
# exactly this compile before. If:
#   (a) an argv-cache entry exists,
#   (b) the scan-cache it references is still valid (mtime match on
#       every source + header), and
#   (c) the built store path still exists,
# then we know the output would be byte-identical to what we already
# built. Skip staging, scan-headers, expression building, and the
# tid-marker check. Just relink the output and exit.
#
# Cost of this fast path: one sha256sum fork, one small file read,
# one batched stat over the .deps file, one readlink+re-link. ~15ms.
_argv_hash=$(printf '%s\n%s\n' "$TOOL" "$*" | sha256sum | cut -c1-32)
_argv_marker="$_NIXGG_THUNKS_DIR/.argv.$_argv_hash"
if [[ -f "$_argv_marker" ]]; then
  IFS=$'\t' read -r _cached_tid _cached_built _cached_scan_key < "$_argv_marker" || true
  if [[ -n "$_cached_built" && -n "$_cached_scan_key" ]] \
      && nixgg::scan_cache_fresh "$_cached_scan_key"; then
    _cached_local=$(nixgg::resolve_store_path "$_cached_built")
    out_basename=$(basename "$output")
    if [[ -e "$_cached_local/$out_basename" ]]; then
      nixgg::link_store_to_output "$_cached_built" "$output"
      nixgg::log "argv-cache hit $source -> $output ($_cached_built)"
      nixgg::emit "$(jq -cn --arg tool "$TOOL" --arg source "$source" \
                           --arg output "$output" --arg built "$_cached_built" \
        '{event: "compile", kind: "argv_cache_hit", tool: $tool,
          source: $source, output: $output, built: $built}')"
      exit 0
    fi
  fi
fi

nixgg::log "compile $source -> $output"
if (( ${#passthrough[@]} )); then
  nixgg::log "  raw flags: [$(printf "'%s' " "${passthrough[@]}")]"
else
  nixgg::log "  raw flags: []"
fi

# ── 2. Discover headers + project root via scan-headers.sh ─────────
#
# scan-headers.sh emits:
#   stdout: one `<abs>\t<staged-rel>` per header.
#   stderr: `PROJECT_ROOT=<path>`, `STAGED_IFLAG=-I<rel>`*, `STORE_IFLAG=-I/nix/store/…`*.
#
# Run it once, capturing both streams. We don't want scan-headers'
# stderr going straight to the console (its regular error msgs also
# use stderr), so we split via fd 3.

scan_out=$(mktemp)
scan_err=$(mktemp)
trap 'rm -f "$scan_out" "$scan_err"' EXIT

if ! nixgg::scan_headers_cached "$(dirname "$NIXGG_REAL_CC")/$TOOL" "$source" "${passthrough[@]}" \
      > "$scan_out" 2> "$scan_err"; then
  cat "$scan_err" >&2
  exit 1
fi

project_root=""
staged_iflags=()
store_iflags=()
while IFS= read -r line; do
  case "$line" in
    PROJECT_ROOT=*)  project_root="${line#PROJECT_ROOT=}" ;;
    STAGED_IFLAG=*)  staged_iflags+=( "${line#STAGED_IFLAG=}" ) ;;
    STORE_IFLAG=*)   store_iflags+=(  "${line#STORE_IFLAG=}" )  ;;
    *)               echo "$line" >&2 ;;
  esac
done < "$scan_err"

if [[ -z "$project_root" ]]; then
  echo "compile-driver: scan-headers gave no PROJECT_ROOT" >&2
  exit 1
fi

headers=()
header_rels=()
while IFS=$'\t' read -r abs rel; do
  [[ -z "$abs" ]] && continue
  headers+=( "$abs" )
  header_rels+=( "$rel" )
done < "$scan_out"

if (( ${#header_rels[@]} )); then
  nixgg::log "  headers: [$(printf "'%s' " "${header_rels[@]}")]"
else
  nixgg::log "  headers: (none)"
fi
if (( ${#store_iflags[@]} )); then
  nixgg::log "  store -I: [$(printf "'%s' " "${store_iflags[@]}")]"
fi
nixgg::log "  project root: $project_root"

# ── 3. Stage source + headers into .nixgg/srcs/<tu-id>/ ─────────────
# Each TU gets its own staging dir populated with hardlinks. Reused
# across rebuilds when nothing changed (inode-match check). The thunk
# references the dir as a relative path so Nix imports it at eval time,
# no `nix store add` round-trip per shim invocation.

src_abs=$(realpath -m "$source")
src_rel="${src_abs#"$project_root"/}"

# TU identity: stable per output-path across rebuilds, filesystem-safe.
# The output is typically a relative path like `src/foo/bar.o`; we
# slugify to `src-foo-bar` so the dir name doesn't need escaping.
tu_id=$(printf '%s' "${output%.o}" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '_')

stage_args=( "$src_abs" "$src_rel" )
for k in "${!headers[@]}"; do
  stage_args+=( "${headers[k]}" "${header_rels[k]}" )
done
_NIXGG_STAGE_DIR="" _NIXGG_STAGE_REUSED=""
nixgg::stage_sources "$tu_id" "$project_root" "${stage_args[@]}"
staged="$_NIXGG_STAGE_DIR"
stage_reused="$_NIXGG_STAGE_REUSED"

# Relative path from thunk dir to staging dir, for the Nix expression.
# Thunks live in $_NIXGG_THUNKS_DIR/, srcs live in $_NIXGG_SRCS_DIR/;
# both share the same parent (.nixgg/), so the relative form is
# `../srcs/<tu-id>`.
src_relpath="../$(basename "$_NIXGG_SRCS_DIR")/$tu_id"
nixgg::log "  staged src: $staged  (source @ $src_rel)"

# ── 4. Build sandbox_flags = passthrough (minus include search) + staged + store ─

sandbox_flags=()
i=0
while (( i < ${#passthrough[@]} )); do
  a="${passthrough[i]}"
  case "$a" in
    -I?*) i=$((i+1)); continue ;;   # -I<path> attached
    -I|-isystem|-iquote|-idirafter|-include)
      i=$((i+2)); continue           # -I <path> separated
      ;;
    *) sandbox_flags+=( "$a" ); i=$((i+1)) ;;
  esac
done
sandbox_flags+=( "${staged_iflags[@]}" )
if (( ${#store_iflags[@]} )); then
  sandbox_flags+=( "${store_iflags[@]}" )
fi

# ── 5. Assemble the Nix expression (same for both modes) ──────────
wrapper_env=$(nixgg::wrapper_env_json)
tool_basename="$TOOL"
out_basename=$(basename "$output")
if (( ${#sandbox_flags[@]} == 0 )); then
  flags_json='[]'
else
  flags_json=$(printf '%s\n' "${sandbox_flags[@]}" | jq -R . | jq -s .)
fi
store_deps_json=$(nixgg::store_deps_from "$flags_json" "$wrapper_env")

expr=$(cat <<NIX
import $NIXGG_NIX_HELPERS/builder.nix {
  toolBasename   = "$tool_basename";
  srcTree        = $src_relpath;
  source         = "$src_rel";
  outName        = "$out_basename";
  flagsJSON      = ''$flags_json'';
  storeDepsJSON  = ''$store_deps_json'';
  wrapperEnvJSON = ''$wrapper_env'';
}
NIX
)

# Deterministic id of *this* thunk expression — same value the
# placeholder path computes. Used by the realise-mode short-circuit
# below to detect when nothing about the compile (source, flags, env,
# toolchain) has changed vs. the last successful build.
tid=$(nixgg::thunk_id "$expr")

# ── 6a. Placeholder mode: write .nix thunk, drop marker ──────────
if [[ "$(nixgg::mode_for "$source")" == "placeholder" ]]; then
  thunk_path=$(nixgg::write_thunk "$expr")
  nixgg::link_placeholder "$output" "$thunk_path"
  nixgg::log "  thunk:      $thunk_path"
  nixgg::emit "$(jq -cn --arg tool "$TOOL" --arg source "$source" \
                       --arg output "$output" --arg thunk "$thunk_path" \
    '{event: "compile", kind: "thunk", tool: $tool,
      source: $source, output: $output, thunk: $thunk}')"
  exit 0
fi

# ── 6b. Realise mode: eval + copy out ────────────────────────────
# Short-circuit: if the recorded thunk-id for this output matches what
# we'd build now, AND the output symlink still resolves to a live
# store path, skip `nix build` entirely. Saves a daemon round-trip per
# shim on warm rebuilds — the actual point of the whole design.
# Marker records `<tid>\t<store-path>` from the last successful realise
# for this TU. On rebuild we can short-circuit purely from this — even
# if make just deleted the .o symlink, we recreate it pointing at the
# same store output and skip `nix build`. This is the actual point of
# the whole staging/caching design.
tid_marker="$_NIXGG_THUNKS_DIR/.tid.$tu_id"
old_tid=""; old_built=""
if [[ -f "$tid_marker" ]]; then
  IFS=$'\t' read -r old_tid old_built < "$tid_marker" || true
fi
if [[ "$old_tid" == "$tid" && -n "$old_built" ]]; then
  # Realise-mode short-circuit: same thunk id AND the previously-built
  # store output still exists on disk → just re-link and go.
  # `link_store_to_output` expects the canonical /nix/store/... path;
  # we recorded that.
  built_local=$(nixgg::resolve_store_path "$old_built")
  if [[ -e "$built_local/$out_basename" ]]; then
    nixgg::link_store_to_output "$old_built" "$output"
    # Also refresh the argv-keyed marker so subsequent invocations
    # can short-circuit before scan-headers/staging even run.
    printf '%s\t%s\t%s\n' "$tid" "$old_built" "${_NIXGG_SCAN_KEY:-}" \
      > "$_argv_marker" 2>/dev/null || true
    nixgg::log "  cache hit:  $output -> $old_built"
    nixgg::emit "$(jq -cn --arg tool "$TOOL" --arg source "$source" \
                         --arg output "$output" --arg built "$old_built" \
                         --arg tid "$tid" \
      '{event: "compile", kind: "cache_hit", tool: $tool,
        source: $source, output: $output, built: $built, thunk_id: $tid}')"
    exit 0
  fi
fi

t0=$(date +%s.%N)
built=$(nixgg::nix_build_expr "$expr")
t1=$(date +%s.%N)

nixgg::log "  built:      $built"
nixgg::link_store_to_output "$built" "$output"
mkdir -p "$_NIXGG_THUNKS_DIR"
printf '%s\t%s\n' "$tid" "$built" > "$tid_marker"
# The argv-keyed marker duplicates the tid+built plus the scan-cache
# key that stored our header list. Reading these three fields at
# start of the next shim invocation is all the fast-path needs.
printf '%s\t%s\t%s\n' "$tid" "$built" "${_NIXGG_SCAN_KEY:-}" > "$_argv_marker"

extras=$(jq -cn --arg tool "$TOOL" --arg source "$source" --arg staged "$staged" \
  '{tool: $tool, source: $source, staged: $staged}')
nixgg::emit_derivation compile output "$output" "$t0" "$t1" "$built" '[]' "$extras"
