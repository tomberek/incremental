{
  inputs,
  lib,
  mkIncremental,
  mkIncrementalPackage,
  ccacheEnv,
  resolveCache,
}:
let
  # `drv` must already be built with ccacheStdenv (a plain
  # stdenv.mkDerivation has no .override for swapping it in after the
  # fact); the assert catches a missing ccacheStdenv at eval time
  # instead of a sandbox "Permission denied" during the build.
  mkIncrementalCcachePackage =
    {
      name,
      system,
      pkgs,
      drv,
      phase,
      cache ? inputs.cache,
      nuke ? false, # ccache manages its own dir
      keepIncremental ? !(cache ? packages),
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
    in
    (mkIncrementalPackage {
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
    }).overrideAttrs
      (old: {
        # env.setup needs CCACHE_DIR live, which inc.restore just set
        # in ${phase} — so it has to run after, in one more layer.
        ${phase} = old.${phase} + env.setup;
        # Overrides the inherited passthru.withCache from
        # mkIncrementalPackage — that one skips env.setup, which
        # would silently drop CCACHE_SLOPPINESS/debug-logging/report.
        passthru = old.passthru // {
          withCache =
            cacheFlake:
            mkIncrementalCcachePackage {
              inherit
                name
                system
                pkgs
                drv
                phase
                nuke
                ;
              keepIncremental = inc.keepIncremental;
              cache = resolveCache cacheFlake;
            };
        };
      });
in
mkIncrementalCcachePackage
