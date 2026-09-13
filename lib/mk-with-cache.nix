# Shared shape for `passthru.withCache`: call `mkFn` again with the
# same args, just `cache` resolved from a flake ref/attrset and
# `keepIncremental` pinned to whatever this build actually used.
# `keepIncremental` is passed in already resolved (not re-defaulted)
# — it has to stay fixed regardless of which cache is passed in, same
# reason `mk-incremental.nix`'s `outputs` has to stay structurally
# constant: a varying value changes the derivation hash, breaking
# dependents' -I/-isystem-keyed caching.
mkFn: args: keepIncremental: cacheFlake:
mkFn (
  args
  // {
    inherit keepIncremental;
    # cacheFlake is either a rev-pinned flake ref (fetched here) or
    # an already-fetched flake attrset (e.g. from `checks`, where
    # there's no ref to fetch).
    cache = if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake;
  }
)
