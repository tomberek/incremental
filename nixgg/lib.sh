# nixgg shared driver library — sourced by the *-driver.sh shims.
#
# Provides:
#   nixgg::log MSG                          — [nixgg] MSG on stderr
#   nixgg::alt_store_prefix                 — on-disk root of alt store (or "")
#   nixgg::resolve_store_path PATH          — /nix/store/... -> on-disk path
#   nixgg::mode_for FILENAME                — "realise" or "placeholder"
#   nixgg::thunk_id PAYLOAD_JSON            — deterministic 32-char id
#   nixgg::write_thunk EXPR                 — persist .nix thunk, echo abs path
#   nixgg::link_placeholder OUTPUT THUNK    — symlink OUTPUT → THUNK.nix
#   nixgg::link_store_to_output STORE OUT   — symlink OUT → STORE/<basename>
#   nixgg::classify_target PATH             — "absent" | "store <p>" | "thunk <p>" | "regular"
#   nixgg::cache_hit_of SECS                — echoes true/false
#   nixgg::emit EVENT_JSON                  — append to NIXGG_LOG if set
#   nixgg::wrapper_env_json                  — JSON object of NIX_CFLAGS_* etc
#   nixgg::store_deps_from FLAGS_JSON [ENV_JSON]  — JSON array of /nix/store roots
#   nixgg::real_tool_for NAME               — sibling tool in gcc-wrapper dir
#   nixgg::nix_env_setup                    — export NIX_REMOTE + NIX_CONFIG
#
# Depends on: jq, sha256sum, coreutils.

# Required at source time.
: "${NIXGG_REAL_CC:?}"
: "${NIXGG_NIX:?}"
: "${NIXGG_STORE:?}"
: "${NIXGG_ROOT:?}"
: "${NIXGG_COMPILER_ROOT:?}"
: "${NIXGG_BASH_ROOT:?}"
: "${NIXGG_COREUTILS_ROOT:?}"

_NIXGG_MODE="${NIXGG_MODE:-realise}"
_NIXGG_THUNKS_DIR="${NIXGG_THUNKS_DIR:-$PWD/.nixgg/thunks}"
_NIXGG_LOG="${NIXGG_LOG:-}"

# @rspfile expansion lives in shims/_dispatch.sh (needs to run before
# shim dispatch chooses compile vs link based on the presence of -c).

nixgg::log() {
  printf '[nixgg] %s\n' "$*" >&2
}

nixgg::alt_store_prefix() {
  case "$NIXGG_STORE" in
    local\?root=*) printf '%s' "${NIXGG_STORE#local?root=}" ;;
    *)             printf '' ;;
  esac
}

nixgg::resolve_store_path() {
  printf '%s%s' "$(nixgg::alt_store_prefix)" "$1"
}

nixgg::mode_for() {
  # Configure-phase probes must realise even in placeholder mode so
  # the configure system sees actual outputs. Both autoconf and CMake
  # invoke `cc` on tiny throwaway sources with predictable names.
  if [[ "$_NIXGG_MODE" != "placeholder" ]]; then
    printf 'realise'
    return
  fi
  local path="$1" base
  base="$(basename "$path")"
  # Autoconf: `conftest.c`, `conftest.cpp`, `conftest.o`, `conftest*`.
  case "$base" in
    conftest*) printf 'realise'; return ;;
  esac
  # CMake: `testCCompiler.c`, `CMakeCXXCompilerId.cpp`, `CheckXxx*.c`.
  case "$base" in
    test?CompilerABI*|test?Compiler*|CMake?CompilerId*|CMakeCCompilerABI*|CMakeCXXCompilerABI*)
      printf 'realise'; return ;;
    CheckFunctionExists*|CheckIncludeFile*|CheckIncludeFiles*|CheckSymbolExists*|CheckTypeSize*|CheckCSourceCompiles*|CheckCXXSourceCompiles*|CheckCSourceRuns*|CheckCXXSourceRuns*)
      printf 'realise'; return ;;
  esac
  # Anything under CMake's TryCompile scratch directories — the
  # filenames vary but the path always contains CMakeFiles/CMakeScratch.
  case "$path" in
    */CMakeFiles/CMakeScratch/*|*/CMakeFiles/CMakeTmp/*)
      printf 'realise'; return ;;
  esac
  printf 'placeholder'
}

nixgg::thunk_id() {
  # Deterministic id from the .nix expression body.
  printf '%s' "$1" | sha256sum | cut -c1-32
}

# Write a Nix-expression thunk. The caller passes the full expression
# text (which imports nix/builder.nix / nix/linker.nix / nix/archiver.nix); we hash
# it, drop it in $NIXGG_THUNKS_DIR/<id>.nix, and echo the absolute path.
# Idempotent — same expression → same id → existing file untouched.
nixgg::write_thunk() {
  local expr="$1" tid path tmp
  tid=$(nixgg::thunk_id "$expr")
  mkdir -p "$_NIXGG_THUNKS_DIR"
  path="$_NIXGG_THUNKS_DIR/$tid.nix"
  if [[ ! -e "$path" ]]; then
    tmp="$path.tmp.$$"
    printf '%s\n' "$expr" > "$tmp"
    mv "$tmp" "$path"
  fi
  printf '%s' "$path"
}

# Symlink OUTPUT → thunk-path. Placeholder mode's representation:
# the target IS the symlink, its resolved destination IS the .nix
# thunk. No sidecar, no stub file.
nixgg::link_placeholder() {
  local output="$1" thunk_path="$2"
  mkdir -p "$(dirname "$output")"
  ln -sfn "$thunk_path" "$output"
}

# Symlink OUT → the on-disk location of STORE_PATH/<basename OUT>.
# Realise mode's representation. When using an alt store the target
# includes the alt-store prefix so the symlink actually resolves; when
# using the system store the prefix is empty and the symlink points at
# /nix/store/... directly.
# Downstream tools that follow symlinks (ld, ar, gcc, …) see a real
# file with real bytes; classify_target's `readlink -f` strips the alt
# prefix by looking for `/nix/store/…` inside the resolved path.
nixgg::link_store_to_output() {
  local store_path="$1" final="$2"
  local src="$(nixgg::resolve_store_path "$store_path")/$(basename "$final")"
  if [[ ! -e "$src" ]]; then
    printf 'nixgg: expected %s to exist after build\n' "$src" >&2
    return 1
  fi
  mkdir -p "$(dirname "$final")"
  ln -sfn "$src" "$final"
}

# Classify a target file. Prints one of:
#   absent
#   store <canonical-store-path>  (symlink → the store, alt-prefix stripped)
#   thunk <abs-thunk-nix-path>    (symlink → …/thunks/<id>.nix)
#   regular                       (real file or unrecognised symlink)
#
# For alt stores the on-disk path is like /tmp/nixgg-store/nix/store/…;
# we strip that prefix so downstream nix expressions get the canonical
# /nix/store/… form.
nixgg::classify_target() {
  local t="$1"
  if [[ ! -e "$t" && ! -L "$t" ]]; then
    printf 'absent\n'
    return
  fi
  if [[ ! -L "$t" ]]; then
    printf 'regular\n'
    return
  fi
  local dest
  dest=$(readlink -f "$t" 2>/dev/null || readlink "$t")
  # Strip alt-store on-disk prefix so we always report /nix/store/... form.
  local alt="$(nixgg::alt_store_prefix)"
  local canonical="$dest"
  if [[ -n "$alt" && "$dest" == "$alt"/nix/store/* ]]; then
    canonical="${dest#"$alt"}"
  fi
  # Store path is the directory holding the output file; strip the file.
  # Match /nix/store/<hash-name>[/<anything>] → keep just the dir prefix.
  case "$canonical" in
    /nix/store/*)
      # Keep everything up to the store-path directory (first 3 path parts).
      local trimmed="${canonical#/nix/store/}"
      trimmed="${trimmed%%/*}"
      printf 'store /nix/store/%s\n' "$trimmed"
      ;;
    *.nix) printf 'thunk %s\n' "$dest" ;;
    *)     printf 'regular\n' ;;
  esac
}

nixgg::cache_hit_of() {
  # Cheap heuristic: builds under 400ms are treated as cache hits.
  # Correct with `nix log`, but this is good enough for the activity log.
  awk -v e="$1" 'BEGIN { print (e < 0.4) ? "true" : "false" }'
}

nixgg::emit() {
  [[ -z "$_NIXGG_LOG" ]] && return 0
  local event="$1" ts cwd
  ts=$(date +%s.%N)
  cwd="$PWD"
  printf '%s\n' "$event" \
    | jq -cS --arg ts "$ts" --arg cwd "$cwd" \
        '. + {ts: ($ts | tonumber), cwd: $cwd}' \
    >> "$_NIXGG_LOG"
}

# Which env vars does the Nix gcc-wrapper look for?
_NIXGG_WRAPPER_ENV_KEYS=(
  NIX_CFLAGS_COMPILE
  NIX_CFLAGS_LINK
  NIX_LDFLAGS
  NIX_HARDENING_ENABLE
)

# Detect the target triple used to key wrapper env vars.
nixgg::_detect_triple() {
  # Look for NIX_CC_WRAPPER_TARGET_HOST_<triple>=1
  local k
  while IFS='=' read -r k _; do
    case "$k" in
      NIX_CC_WRAPPER_TARGET_HOST_*)
        printf '%s' "${k#NIX_CC_WRAPPER_TARGET_HOST_}"
        return 0
        ;;
    esac
  done < <(env)
  return 0
}

nixgg::wrapper_env_json() {
  local triple base val out='{}'
  triple=$(nixgg::_detect_triple)

  if [[ -n "$triple" ]]; then
    out=$(printf '%s' "$out" | jq -cS \
      --arg k "NIX_CC_WRAPPER_TARGET_HOST_$triple" \
      '. + {($k): "1"}')
  fi

  for base in "${_NIXGG_WRAPPER_ENV_KEYS[@]}"; do
    val="${!base:-}"
    if [[ -n "$triple" ]]; then
      local suffixed="${base}_${triple//-/_}"
      if [[ -n "${!suffixed:-}" ]]; then
        val="${!suffixed}"
      fi
    fi
    [[ -z "$val" ]] && continue
    out=$(printf '%s' "$out" | jq -cS --arg k "$base" --arg v "$val" '. + {($k): $v}')
    if [[ -n "$triple" ]]; then
      out=$(printf '%s' "$out" | jq -cS --arg k "${base}_${triple//-/_}" --arg v "$val" '. + {($k): $v}')
    fi
  done
  printf '%s' "$out"
}

# Given a JSON array of flag strings and (optionally) a JSON object of
# wrapper env vars, emit a JSON array of /nix/store/<name-hash> roots
# referenced by any of them.
nixgg::store_deps_from() {
  local flags_json="$1" env_json="${2:-{\}}"
  {
    printf '%s\n' "$flags_json" | jq -r '.[]?'
    printf '%s\n' "$env_json"   | jq -r 'to_entries[]?.value'
  } | { grep -oE '/nix/store/[a-z0-9]{32}-[^/[:space:]:"]+' || true; } \
    | sort -u \
    | jq -Rn '[inputs | select(length > 0)]'
}

# Sibling tool in the gcc-wrapper's bin/ (ar, ranlib, nm, …).
nixgg::real_tool_for() {
  local name="$1" wrapper_bin
  wrapper_bin=$(dirname "$NIXGG_REAL_CC")
  printf '%s/%s' "$wrapper_bin" "$name"
}

# Set NIX_REMOTE + NIX_CONFIG so downstream `nix build` calls target
# the correct store.
nixgg::nix_env_setup() {
  export NIX_REMOTE=""
  export NIX_CONFIG="experimental-features = nix-command flakes ca-derivations
store = $NIXGG_STORE
"
}

# Build a Nix `inputs = [ … ];` list literal from a JSON array of
# {ref_kind, ref, name}. `ref_kind` is either "store" (existing store
# path → wrap in builtins.storePath) or "nix" (path to another thunk
# .nix file → import it). Emits:
#   [ { drv = <expr>; name = "…"; } … ]
nixgg::inputs_nix_from_json() {
  local inputs_json="$1"
  echo "$inputs_json" | jq -r '
    map(
      (if .ref_kind == "store"
         then "builtins.storePath \"" + .ref + "\""
       else "import " + .ref
       end) as $drv
      | "{ drv = " + $drv + "; name = \"" + .name + "\"; }"
    ) | "[ " + join(" ") + " ]"'
}

# Run `nix build` against the alt store on the given expression body,
# print the resulting /nix/store/... path. We route through a temp
# `--file <foo.nix>` because `nix build --expr` implies pure-eval mode
# in newer Nix, which forbids `import /nix/store/…` calls (which every
# thunk uses to reach the flake-realised helpers).
nixgg::nix_build_expr() {
  local expr="$1" tmp out
  nixgg::nix_env_setup
  tmp=$(mktemp -t nixgg-expr-XXXXXX.nix)
  # Ensure the temp file is cleaned up even on error.
  trap 'rm -f "$tmp"' RETURN
  printf '%s\n' "$expr" > "$tmp"
  out=$("$NIXGG_NIX" build -L --no-link --print-out-paths --file "$tmp" | tail -1)
  printf '%s' "$out"
}

# Emit an activity-log event for a successful "derivation" realise.
# args: event_kind (compile|link|ar) target_key target_val started_at ended_at built_path inputs_json extras_json
nixgg::emit_derivation() {
  local event="$1" tkey="$2" tval="$3" t0="$4" t1="$5" built="$6" inputs_json="$7" extras_json="${8:-{\}}"
  local elapsed hit
  elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN { print b - a }')
  hit=$(nixgg::cache_hit_of "$elapsed")
  nixgg::emit "$(jq -cn \
    --arg event "$event" --arg tkey "$tkey" --arg tval "$tval" \
    --arg built "$built" --arg elapsed "$elapsed" --arg hit "$hit" \
    --argjson inputs "$inputs_json" --argjson extras "$extras_json" \
    '{event: $event, kind: "derivation", ($tkey): $tval, inputs: $inputs,
      built: $built, elapsed: ($elapsed | tonumber),
      cache_hit: ($hit == "true")} + $extras')"
}
