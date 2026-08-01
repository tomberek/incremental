#!/usr/bin/env bash
# scan-headers.sh — awk-based header discovery for a compile invocation.
#
# Given a source file + compile flags, invoke `gcc -MM -MG` to
# enumerate headers, then emit one line per header:
#
#     <abs-path>\t<staged-rel-path>
#
# where <staged-rel-path> is the path the header should be staged to
# under the project root (= commonpath of cwd + every non-store -I).
# Store-path headers are skipped (referenced verbatim from the store).
#
# Usage:
#     scan-headers.sh <real-cc> <source> [flag...]
#
# Requires: awk, gcc/g++, bash. Stateless — no side effects on disk.

set -euo pipefail

if (($# < 2)); then
  echo "usage: scan-headers.sh <real-cc> <source> [flag...]" >&2
  exit 2
fi

real_cc="$1"
source_rel="$2"
shift 2
flags=("$@")

cwd="$(pwd -P)"

# 1. Extract -I / -isystem / -iquote / -idirafter / -include values.
#    Attached (-I/path) and separated (-I /path) both handled.
include_dirs=()
i=0
while (( i < ${#flags[@]} )); do
  a="${flags[i]}"
  case "$a" in
    -I?*)          include_dirs+=( "${a:2}" ) ;;
    -I|-isystem|-iquote|-idirafter|-include)
                   i=$((i+1)); include_dirs+=( "${flags[i]}" ) ;;
  esac
  i=$((i+1))
done

# 2. Resolve each include dir. Split into "user" dirs (staged) and
#    "store" dirs (path IS the identity — passed verbatim in the shim).
user_dirs=( "$cwd" )
for d in "${include_dirs[@]:-}"; do
  [[ -z "$d" ]] && continue
  case "$d" in
    /*) abs="$d" ;;
    *)  abs="$(cd "$d" 2>/dev/null && pwd -P || echo "$cwd/$d")" ;;
  esac
  case "$abs" in
    /nix/store/*) ;;  # store: skip staging
    *)            user_dirs+=( "$abs" ) ;;
  esac
done

# 3. Project root = longest common path prefix of every user dir.
project_root="${user_dirs[0]}"
for d in "${user_dirs[@]}"; do
  # Trim project_root down to what's still shared.
  while [[ "${d#"$project_root"/}" == "$d" && "$d" != "$project_root" ]]; do
    project_root="${project_root%/*}"
    [[ -z "$project_root" ]] && { project_root=/; break; }
  done
done

# 4. Run gcc -MM -MG and let awk emit one dep per line.
#    -MM: skip system headers, no absolute paths (usually).
#    -MG: don't fail on missing generated headers; print them as bare names.
#
#    awk joins backslash-continuations, drops the "target:" prefix,
#    prints each dep on its own line.
# Strip any of the caller's -M* dep-generation flags so ours (`-MF -`)
# aren't overridden. CMake in particular passes `-MD -MT <o> -MF <d>`.
scan_flags=()
skip_next=0
for f in "${flags[@]}"; do
  if (( skip_next )); then skip_next=0; continue; fi
  case "$f" in
    -MF|-MT|-MQ)   skip_next=1; continue ;;    # 2-arg forms
    -M|-MM|-MG|-MP|-MD|-MMD) continue ;;         # 1-arg forms
  esac
  scan_flags+=( "$f" )
done

deps=$("$real_cc" -MM -MG -MF - "$source_rel" "${scan_flags[@]}" 2>/dev/null \
       | awk '
           # Handle line continuations first.
           /\\$/ { sub(/\\$/, ""); buf = buf $0; next }
           { buf = buf $0 }
           END { print buf }
         ' \
       | awk -v src="$source_rel" '
           {
             # Strip "target: " prefix on the first line.
             sub(/^[^:]+:[[:space:]]*/, "")
             # Split remaining tokens on whitespace, one per output.
             n = split($0, toks, /[[:space:]]+/)
             for (i = 1; i <= n; i++)
               if (toks[i] != "" && toks[i] != src)
                 print toks[i]
           }
         ')

# 5. Resolve + stage each dep. Emit "<abs>\t<staged-rel>".
#    Absolute /nix/store/... paths: skip. Others: search cwd + user
#    -I dirs (in order) for the token; the first match wins.
while IFS= read -r tok; do
  [[ -z "$tok" ]] && continue

  # Absolute path?
  if [[ "$tok" == /* ]]; then
    case "$tok" in
      /nix/store/*) continue ;;
    esac
    [[ -e "$tok" ]] || continue
    abs="$tok"
  else
    abs=""
    for d in "${user_dirs[@]}"; do
      cand="$d/$tok"
      if [[ -e "$cand" ]]; then
        abs="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
        break
      fi
    done
    [[ -z "$abs" ]] && continue  # -MG bare name we can't find
  fi

  # Skip source itself.
  src_abs="$(cd "$(dirname "$source_rel" 2>/dev/null || echo .)" && pwd -P)/$(basename "$source_rel")"
  [[ "$abs" == "$src_abs" ]] && continue

  # Skip anything already in the store.
  case "$abs" in
    /nix/store/*) continue ;;
  esac

  # Stage relative to project_root.
  if [[ "$abs" == "$project_root"/* ]]; then
    staged="${abs#"$project_root"/}"
  elif [[ "$abs" == "$project_root" ]]; then
    staged="$(basename "$abs")"
  else
    echo "scan-headers: $abs is outside project root $project_root" >&2
    exit 1
  fi

  printf '%s\t%s\n' "$abs" "$staged"
done <<< "$deps" | sort -u

# 6. Print the project root and store -I flags on stderr for the
#    caller to consume.
#
# STAGED_IFLAG lines: for every user (non-store) include dir + cwd,
# emit `-I<path>` relative to project_root. These are the flags the
# sandbox uses to find headers inside the staged tree.
echo "PROJECT_ROOT=$project_root" >&2
for p in "${user_dirs[@]}"; do
  if [[ "$p" == "$project_root" ]]; then
    echo "STAGED_IFLAG=-I." >&2
  else
    echo "STAGED_IFLAG=-I${p#"$project_root"/}" >&2
  fi
done
for d in "${include_dirs[@]:-}"; do
  case "$d" in
    /nix/store/*) echo "STORE_IFLAG=-I$d" >&2 ;;
  esac
done
