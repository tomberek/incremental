{ inputs, mkIncrementalPackage }:

# Go and Zig both just need mkIncrementalPackage with a fixed
# cacheVars/phase — shared shape for mk-incremental-go-package.nix and
# mk-incremental-zig-package.nix.
{ cacheVars, phase }:
{
  name,
  system,
  pkgs,
  drv,
  cache ? inputs.cache,
  nuke ? true,
  keepIncremental ? !(cache ? packages),
  extraPostInstall ? (_: ""),
}:
mkIncrementalPackage {
  inherit
    name
    system
    pkgs
    drv
    cache
    nuke
    keepIncremental
    extraPostInstall
    cacheVars
    phase
    ;
}
