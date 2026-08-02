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
# Manifest of caller-visible symlink → thunk-id. One file per thunk;
# each file lists absolute paths of symlinks pointing at that thunk.
# `cmd_force` uses this to promote every symlink of every realised
# thunk, so we don't need a post-hoc filesystem sweep.
_NIXGG_SYMLINKS_DIR="${NIXGG_SYMLINKS_DIR:-$(dirname "$_NIXGG_THUNKS_DIR")/symlinks}"
# Per-TU staging dirs — one per compilation unit, populated with
# hardlinks to source + discovered headers. Thunks reference these
# via `srcTree = ../srcs/<tu-id>;` (a relative path expression),
# so Nix imports the dir at eval time and we avoid `nix store add`
# on every shim invocation.
_NIXGG_SRCS_DIR="${NIXGG_SRCS_DIR:-$(dirname "$_NIXGG_THUNKS_DIR")/srcs}"
# Cached scan-headers.sh output. Cache key = sha of (source-abs, flags).
# Invalidation: if the mtime of any file the cached scan listed has
# advanced past the recorded mtime, we re-run gcc -MM. Saves ~50ms/TU
# on warm rebuilds (dominant scan-headers cost is spawning gcc).
_NIXGG_SCANS_DIR="${NIXGG_SCANS_DIR:-$(dirname "$_NIXGG_THUNKS_DIR")/scans}"
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

# Record that a caller-visible symlink at $output points at thunk id
# $tid, so `nixgg force` can find every symlink of every realised
# thunk without scanning the filesystem.
#
# Manifest layout: $NIXGG_SYMLINKS_DIR/<tid>, one absolute path per
# line. Append-only per-thunk file → concurrent shims writing under
# `make -j` don't contend as long as they hit different thunks. Bash
# `>>` is atomic below PIPE_BUF; our paths are short.
nixgg::_record_symlink() {
  local output="$1" tid="$2"
  local abs manifest
  # `realpath -m --no-symlinks` normalises path components without
  # following symlinks — critical here because `output` typically IS
  # a symlink (either the one we just wrote, or a leftover from a
  # prior invocation).
  abs=$(realpath -m --no-symlinks "$output")
  manifest="$_NIXGG_SYMLINKS_DIR/$tid"
  mkdir -p "$_NIXGG_SYMLINKS_DIR"
  # Guard against duplicate entries. Cheap for small manifests.
  if [[ -f "$manifest" ]] && grep -qxF "$abs" "$manifest" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$abs" >> "$manifest"
}

# Register a GC root for a realised store path, so `nix-store --gc`
# preserves it as long as our manifest points at it.
#
# Alt store (`local?root=/some/path`): gcroots live at
#   /some/path/nix/var/nix/gcroots/nixgg/
# System store: /nix/var/nix/gcroots/per-user/$USER/nixgg/ (this dir
# has to be created by the daemon/user first; if it's not, we skip).
nixgg::_register_gcroot() {
  local store_path="$1" target="$2"
  local root_dir alt
  alt="$(nixgg::alt_store_prefix)"
  # Nix's gc walks specific subdirs of gcroots/: `auto/` (indirect
  # roots, symlinks-to-symlinks), `per-user/` (writable without root),
  # and a few others. Anywhere else is invisible. Use per-user under
  # the alt store's gcroots too, since it's the most portable subpath.
  if [[ -n "$alt" ]]; then
    root_dir="$alt/nix/var/nix/gcroots/per-user/${USER:?}/nixgg"
  else
    root_dir="/nix/var/nix/gcroots/per-user/${USER:?}/nixgg"
  fi
  mkdir -p "$root_dir" 2>/dev/null || return 0
  [[ -w "$root_dir" ]] || return 0
  local key
  key=$(printf '%s' "$(realpath -m --no-symlinks "$target")" | sha1sum | cut -c1-32)
  ln -sfn "$store_path" "$root_dir/$key"
}

# Symlink OUTPUT → thunk-path. Placeholder mode's representation:
# the target IS the symlink, its resolved destination IS the .nix
# thunk. No sidecar, no stub file. Also records the symlink in the
# manifest so `nixgg force` knows where to promote it.
nixgg::link_placeholder() {
  local output="$1" thunk_path="$2"
  mkdir -p "$(dirname "$output")"
  ln -sfn "$thunk_path" "$output"
  local tid_base tid
  tid_base="$(basename "$thunk_path")"
  tid="${tid_base%.nix}"
  nixgg::_record_symlink "$output" "$tid"
}

# Symlink OUT → the on-disk location of STORE_PATH/<basename OUT>.
# Realise mode's representation. Downstream tools that follow symlinks
# see a real file with real bytes; classify_target strips any alt-store
# prefix to report the canonical /nix/store/… path.
#
# In realise mode we also record the promotion in the manifest and
# register a GC root, so the store output is protected against
# `nix-store --gc` for as long as the caller-visible symlink exists.
nixgg::link_store_to_output() {
  local store_path="$1" final="$2" tid="${3:-}"
  local src="$(nixgg::resolve_store_path "$store_path")/$(basename "$final")"
  if [[ ! -e "$src" ]]; then
    printf 'nixgg: expected %s to exist after build\n' "$src" >&2
    return 1
  fi
  mkdir -p "$(dirname "$final")"
  ln -sfn "$src" "$final"
  # Record the symlink under the thunk (if the caller supplied one).
  [[ -n "$tid" ]] && nixgg::_record_symlink "$final" "$tid"
  nixgg::_register_gcroot "$store_path" "$final"
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

# Materialize (or reuse) `.nixgg/srcs/<tu_id>/` — a directory of
# hardlinks to $src_abs + every header path. Reuse policy: walk the
# target list; if every hardlink already exists with the same inode as
# the current original AND no extra files remain, keep the dir as-is.
# Any mismatch → nuke + rebuild.
#
# Sets two globals (avoids a subshell for the caller to inspect status):
#   _NIXGG_STAGE_DIR      — absolute path of the staging dir
#   _NIXGG_STAGE_REUSED   — "1" if we kept the existing dir, "" otherwise
nixgg::stage_sources() {
  local tu_id="$1" project_root="$2"; shift 2
  # Remaining args come in pairs: <abs> <rel>. `install` and the
  # inode-match loop both need both, so we pre-split into two arrays.
  local -a abs_paths=() rel_paths=()
  while (( $# > 0 )); do
    abs_paths+=( "$1" )
    rel_paths+=( "$2" )
    shift 2
  done

  local dir="$_NIXGG_SRCS_DIR/$tu_id"
  mkdir -p "$_NIXGG_SRCS_DIR"
  _NIXGG_STAGE_DIR="$dir"

  # Reuse fast path.
  if [[ -d "$dir" ]]; then
    local reuse=1
    local i orig_ino staged_ino
    for ((i=0; i < ${#abs_paths[@]}; i++)); do
      if [[ ! -e "$dir/${rel_paths[i]}" ]]; then reuse=0; break; fi
      orig_ino=$(stat -c '%i' "${abs_paths[i]}" 2>/dev/null || echo 0)
      staged_ino=$(stat -c '%i' "$dir/${rel_paths[i]}" 2>/dev/null || echo 1)
      [[ "$orig_ino" == "$staged_ino" ]] || { reuse=0; break; }
    done
    if (( reuse )); then
      # Guard against stale files (e.g. a header was #include-removed
      # between builds — the file's still on disk from last staging).
      local have want
      want=$(printf '%s\n' "${rel_paths[@]}" | sort -u)
      have=$(cd "$dir" && find . -type f -o -type l 2>/dev/null | sed 's|^\./||' | sort -u)
      if [[ "$want" == "$have" ]]; then
        _NIXGG_STAGE_REUSED=1
        return 0
      fi
    fi
    rm -rf "$dir"
  fi

  mkdir -p "$dir"
  local i
  for ((i=0; i < ${#abs_paths[@]}; i++)); do
    mkdir -p "$dir/$(dirname "${rel_paths[i]}")"
    # Hardlink first; fall back to copy if the src is on a different
    # filesystem or hardlinking fails. We DO NOT chmod the staging —
    # that would apply to the original inode too, making the
    # working-tree source read-only.
    ln "${abs_paths[i]}" "$dir/${rel_paths[i]}" 2>/dev/null \
      || install -Dm644 "${abs_paths[i]}" "$dir/${rel_paths[i]}"
  done
  _NIXGG_STAGE_REUSED=""
}

# Wrapper around scan-headers.sh with an mtime-invalidated cache.
#
#   args:   <real-cc> <source> [flags...]
#   stdout: header list, one per line ("<abs>\t<staged-rel>")
#   stderr: PROJECT_ROOT=/STAGED_IFLAG=/STORE_IFLAG= lines
#
# Cache layout: two files per key under $_NIXGG_SCANS_DIR:
#   <key>.out       — captured stdout of scan-headers.sh
#   <key>.err       — captured stderr (PROJECT_ROOT= etc)
#   <key>.deps      — sha256:mtime per referenced file, one per line;
#                     read on subsequent runs to check whether any of
#                     the discovered inputs changed since we scanned.
#
# The dep list is (source, all headers). We use `stat -c '%Y'` (mtime,
# whole-second). Any file added/removed/mtime-advanced → miss.
nixgg::scan_headers_cached() {
  local real_cc="$1" source="$2"; shift 2
  local flags_hash key out_file err_file deps_file
  # Include real_cc in the key — switching cc <-> c++ has to invalidate.
  flags_hash=$(printf '%s\n%s\n%s\n' "$real_cc" "$source" "$*" | sha256sum | cut -c1-32)
  mkdir -p "$_NIXGG_SCANS_DIR"
  key="$_NIXGG_SCANS_DIR/$flags_hash"
  out_file="$key.out"; err_file="$key.err"; deps_file="$key.deps"

  if [[ -f "$deps_file" ]]; then
    local dep_ok=1 line dep_path dep_mtime cur_mtime
    while IFS=$'\t' read -r dep_path dep_mtime; do
      cur_mtime=$(stat -c '%Y' "$dep_path" 2>/dev/null || echo -)
      if [[ "$cur_mtime" != "$dep_mtime" ]]; then dep_ok=0; break; fi
    done < "$deps_file"
    if (( dep_ok )); then
      cat "$out_file"
      cat "$err_file" >&2
      return 0
    fi
  fi

  # Cache miss. Run the scanner, capture both streams, record dep mtimes.
  local scan_dir
  scan_dir="$(dirname "${BASH_SOURCE[0]}")"
  local tmp_out tmp_err
  tmp_out=$(mktemp "$_NIXGG_SCANS_DIR/.$flags_hash.out.XXXX")
  tmp_err=$(mktemp "$_NIXGG_SCANS_DIR/.$flags_hash.err.XXXX")
  if ! "$scan_dir/scan-headers.sh" "$real_cc" "$source" "$@" \
        > "$tmp_out" 2> "$tmp_err"; then
    cat "$tmp_err" >&2
    rm -f "$tmp_out" "$tmp_err"
    return 1
  fi

  # Record source + every discovered header's mtime.
  local src_abs
  src_abs=$(realpath -m "$source")
  {
    printf '%s\t%s\n' "$src_abs" "$(stat -c '%Y' "$src_abs" 2>/dev/null || echo -)"
    # Each stdout line is "<abs>\t<rel>" — key on abs.
    awk -F'\t' '{print $1}' "$tmp_out" | while IFS= read -r abs; do
      [[ -n "$abs" ]] || continue
      printf '%s\t%s\n' "$abs" "$(stat -c '%Y' "$abs" 2>/dev/null || echo -)"
    done
  } > "$deps_file"
  mv "$tmp_out" "$out_file"
  mv "$tmp_err" "$err_file"

  cat "$out_file"
  cat "$err_file" >&2
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
# For `ref_kind == "nix"` inputs, use `import ./<id>.nix` — a relative
# path that resolves against the thunk file containing the import.
# All thunks live in the same $NIXGG_THUNKS_DIR, so this keeps thunk
# content free of the absolute $PWD (which would otherwise churn CA
# hashes when a project moves).
nixgg::inputs_nix_from_json() {
  local inputs_json="$1"
  echo "$inputs_json" | jq -r '
    map(
      (if .ref_kind == "store"
         then "builtins.storePath \"" + .ref + "\""
       else "import ./" + (.ref | sub(".*/"; ""))
       end) as $drv
      | "{ drv = " + $drv + "; name = \"" + .name + "\"; }"
    ) | "[ " + join(" ") + " ]"'
}

# Run `nix build` against the alt store on the given expression body,
# print the resulting /nix/store/... path. We route through
# `--file <foo.nix>` because `nix build --expr` implies pure-eval mode
# in newer Nix, which forbids `import /nix/store/…` calls (which every
# thunk uses to reach the flake-realised helpers).
#
# The file is written inside $NIXGG_THUNKS_DIR (not /tmp), because the
# expression may contain relative-path references (`srcTree = ../srcs/<tu-id>`)
# that Nix resolves against the file's own directory. Placeholder-mode
# thunks live there too, so realise mode using the same directory keeps
# path resolution consistent.
nixgg::nix_build_expr() {
  local expr="$1" tmp out
  nixgg::nix_env_setup
  mkdir -p "$_NIXGG_THUNKS_DIR"
  tmp=$(mktemp "$_NIXGG_THUNKS_DIR/expr-XXXXXX.nix")
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
