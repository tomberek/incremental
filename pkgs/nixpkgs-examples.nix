{
  inputs,
  system,
  pkgs,
  mkIncrementalAutotoolsPackage,
  ccacheEnv,
}:
# A bigger real-world C package from nixpkgs, to check whether this
# caching approach is viable for speeding up iteration on something
# larger than this repo's own toy examples. Same pattern as
# hello-ccache.nix, just wrapping a real nixpkgs derivation instead of
# pkgs.hello.
#
# jq works well: ~2x wall-clock speedup restoring a warm cache
# (measured 51s -> 23s), 95% real ccache hit rate on a no-op rebuild.
#
# Tried and dropped as examples: curl hits 100% in ccache but shows
# no real speedup — its build time is dominated by man-page
# rendering/install, not compilation, so ccache has nothing to save.
# openssh bakes its own $out into compile-time -D flags
# (-D_PATH_SSH_PROGRAM=..., similar for several other _PATH_* macros)
# — since $out is a different store path on every build with a
# different `cache` input, every single compile command differs
# between builds regardless of source changes, making ccache's key
# unique per-build and the hit rate genuinely 0%. nginx's `./configure`
# isn't autoconf-based and doesn't understand --cache-file at all
# (`error: invalid option "--cache-file=..."`), so it's incompatible
# with mkIncrementalAutotoolsPackage outright.
let
  mkNixpkgsExample =
    name: drv:
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
            ;
          cacheVars = [ "CCACHE_DIR" ];
          # Unlike hello-ccache, this build is big enough that
          # ccache's cache dir picks up real store-path references
          # (e.g. from debug info) — without nuke-refs, that creates a
          # same-derivation cycle between the incremental and main
          # outputs (confirmed: dropping this reproduces "cycle
          # detected ... in the references of output 'bin' from
          # output 'incremental'").
          nuke = true;
          drv = drv.override { stdenv = pkgs.ccacheStdenv; };
          extraPostInstall = _isCached: env.report;
        }).overrideAttrs
          (old: {
            postPatch = old.postPatch + env.setup;
            passthru = old.passthru // {
              withCache =
                cacheFlake:
                mkForCache (if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake);
            };
          });
    in
    mkForCache inputs.cache;
in
{
  nixpkgs-jq = mkNixpkgsExample "nixpkgs-jq" pkgs.jq;
}
