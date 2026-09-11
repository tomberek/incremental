{
  inputs,
  lib,
  mkIncremental,
  mkIncrementalPackage,
  mkIncrementalAutotoolsPackage,
  mkWithCache,
  ccacheEnv,
}:
let
  # `drv` must already be built with ccacheStdenv (a plain
  # stdenv.mkDerivation has no .override for swapping it in after the
  # fact); the assert catches a missing ccacheStdenv at eval time
  # instead of a sandbox "Permission denied" during the build.
  #
  # autotools = true additionally layers on mkIncrementalAutotoolsPackage's
  # --cache-file, for packages with a real ./configure — phase is
  # then always postPatch (that's when --cache-file's own restore
  # needs to already be live) and not a parameter. Plain ccache-only
  # packages (autotools = false, the default) pass their own `phase`
  # instead — whichever hook runs before the compiler does, since
  # that varies when there's no ./configure to anchor on.
  mkIncrementalCcachePackage =
    args@{
      name,
      system,
      pkgs,
      drv,
      autotools ? false,
      phase ?
        if autotools then
          "postPatch"
        else
          (throw "mkIncrementalCcachePackage: `phase` is required when autotools = false."),
      cache ? inputs.cache,
      nuke ? false, # ccache manages its own dir
      keepIncremental ? autotools || !(cache ? packages),
    }:
    assert lib.assertMsg (
      drv.stdenv.cc.pname or "" == "ccache-links-wrapper"
    ) "mkIncrementalCcachePackage: `drv` (${name}) wasn't built with pkgs.ccacheStdenv.";
    let
      inc = mkIncremental {
        inherit
          name
          system
          cache
          nuke
          keepIncremental
          ;
        cacheVars = [ "CCACHE_DIR" ];
      };
      env = ccacheEnv {
        inherit pkgs;
        pname = name;
        dir = inc.dir;
        debugDir = inc.debugDir;
      };
      mkBase =
        if autotools then
          mkIncrementalAutotoolsPackage {
            inherit
              name
              system
              drv
              pkgs
              cache
              nuke
              ;
            cacheVars = [ "CCACHE_DIR" ];
            extraPostInstall = _isCached: env.report;
          }
        else
          mkIncrementalPackage {
            inherit
              name
              system
              drv
              phase
              pkgs
              cache
              nuke
              keepIncremental
              ;
            cacheVars = [ "CCACHE_DIR" ];
            extraPostInstall = _isCached: env.report;
          };
    in
    mkBase.overrideAttrs (old: {
      # env.setup needs CCACHE_DIR live, which inc.restore just set
      # in ${phase} — so it has to run after, in one more layer.
      ${phase} = old.${phase} + env.setup;
      # Overrides the inherited passthru.withCache from
      # mkIncrementalPackage/mkIncrementalAutotoolsPackage — those
      # skip env.setup, which would silently drop
      # CCACHE_SLOPPINESS/debug-logging/report.
      passthru = old.passthru // {
        withCache = mkWithCache mkIncrementalCcachePackage args inc.keepIncremental;
      };
    });
in
mkIncrementalCcachePackage
