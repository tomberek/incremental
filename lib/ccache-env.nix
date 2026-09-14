{
  pkgs,
  pname,
  dir,
  debugDir,
}:

# Shared ccache env/report shell.
{
  setup = ''
    export CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime
    export CCACHE_COMPRESS=1
    export CCACHE_UMASK=007
    export CCACHE_NOINODECACHE=1
    export CCACHE_DEBUG=1
    export CCACHE_DEBUGDIR="${debugDir}"
    ${pkgs.ccache}/bin/ccache --dir "${dir}" --zero-stats > /dev/null
  '';
  report = ''
    ${pkgs.ccache}/bin/ccache --dir "${dir}" --show-stats
    hits=$(${pkgs.ccache}/bin/ccache --dir "${dir}" --print-stats | awk '$1=="direct_cache_hit"||$1=="preprocessed_cache_hit"{s+=$2}END{print s+0}')
    misses=$(${pkgs.ccache}/bin/ccache --dir "${dir}" --print-stats | awk '$1=="cache_miss"{print $2+0}')
    total=$((hits + misses))
    pct=0
    if [ "$total" -gt 0 ]; then pct=$((hits * 100 / total)); fi
    echo "ccache[${pname}]: $hits/$total hits ($pct%)"
    echo "$pct" > "${dir}/ccache-hit-pct" # read by `checks` — see below
    if [ "$misses" -gt 0 ] && [ -d "${debugDir}" ]; then
      echo "ccache[${pname}]: miss reasons (top):"
      find "${debugDir}" -name '*.ccache-log' -exec grep -m1 "Result:" {} + 2>/dev/null \
        | sed -E 's/^.*Result: //' | sort | uniq -c | sort -rn | head -5 \
        | sed "s/^/ccache[${pname}]:   /" || true
    fi
  '';
}
