# Accepts a rev-pinned flake ref (fetched here) or an already-fetched
# flake attrset (e.g. from `checks`, where there's no ref to fetch).
cacheFlake: if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake
