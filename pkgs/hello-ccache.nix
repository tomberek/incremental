{
  inputs,
  system,
  pkgs,
  mkIncrementalAutotoolsPackage,
  ccacheEnv,
}:
let
  mkHelloCcache =
    cache:
    let
      env = ccacheEnv {
        inherit pkgs;
        pname = "hello-ccache";
        dir = "$incremental";
        debugDir = "$incremental/debug-logs";
      };
    in
    (mkIncrementalAutotoolsPackage {
      name = "hello-ccache";
      inherit system cache pkgs;
      cacheVars = [ "CCACHE_DIR" ];
      drv = pkgs.hello.override { stdenv = pkgs.ccacheStdenv; };
      extraPostInstall = _isCached: env.report;
    }).overrideAttrs
      (old: {
        postPatch = old.postPatch + env.setup;
        # Overrides the inherited passthru.withCache from
        # mkIncrementalPackage, which would skip env.setup above.
        passthru = old.passthru // {
          withCache =
            cacheFlake:
            mkHelloCcache (if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake);
        };
      });
in
mkHelloCcache inputs.cache
