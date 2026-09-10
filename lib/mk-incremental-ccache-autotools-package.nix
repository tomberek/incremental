{
  inputs,
  lib,
  mkIncremental,
  mkIncrementalAutotoolsPackage,
  ccacheEnv,
  resolveCache,
}:
let
  # ccache + autoconf's --cache-file together: the combo hello-ccache
  # and nixpkgs-jq/tmux each hand-rolled separately (ccacheEnv wiring,
  # threading `cache` through withCache without losing env.setup).
  # `drv` must already be built with ccacheStdenv, same as
  # mkIncrementalCcachePackage — the assert catches a missing override
  # at eval time instead of a sandbox "Permission denied" mid-build.
  mkIncrementalCcacheAutotoolsPackage =
    {
      name,
      system,
      pkgs,
      drv,
      cache ? inputs.cache,
      nuke ? false,
    }:
    assert lib.assertMsg (
      drv.stdenv.cc.pname or "" == "ccache-links-wrapper"
    ) "mkIncrementalCcacheAutotoolsPackage: `drv` (${name}) wasn't built with pkgs.ccacheStdenv.";
    let
      mkForCache =
        cache:
        let
          env = ccacheEnv {
            inherit pkgs;
            pname = name;
            dir = "$incremental";
            debugDir = "$incremental/debug-logs";
          };
        in
        (mkIncrementalAutotoolsPackage {
          inherit
            name
            system
            cache
            pkgs
            drv
            nuke
            ;
          cacheVars = [ "CCACHE_DIR" ];
          extraPostInstall = _isCached: env.report;
        }).overrideAttrs
          (old: {
            postPatch = old.postPatch + env.setup;
            # Overrides the inherited passthru.withCache from
            # mkIncrementalAutotoolsPackage — that one skips
            # env.setup, which would silently drop
            # CCACHE_SLOPPINESS/debug-logging/report.
            passthru = old.passthru // {
              withCache = cacheFlake: mkForCache (resolveCache cacheFlake);
            };
          });
    in
    mkForCache cache;
in
mkIncrementalCcacheAutotoolsPackage
