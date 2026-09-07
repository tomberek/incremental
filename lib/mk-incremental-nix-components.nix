{
  inputs,
  mkIncremental,
  ccacheEnv,
}:

# NixOS/nix's flake splits `nix` into ~14 Meson/Ninja components
# sharing a scope via overrideAllMesonComponents — an overlay
# applied to every component, so building nix-cli applies it
# underneath too. withUnityBuild = false: unity builds merge many
# .cc files into one translation unit, wrecking ccache's per-file
# hit rate. withAWS = false on nix-store: aws-crt-cpp resolves via
# CMake, whose compiler-detection breaks under a swapped
# ccacheStdenv.
#
# Only `target` gets a cache-varying restore script; every
# dependency gets a fixed one. `cache` is a nested evaluation of
# this same flake with its own `cache` input — if a dependency's
# script varied with caching state, it would build a different
# derivation (different `dev` output path) in `cache`'s tree vs.
# the target's tree, and dependents embed that path in every
# -I/-isystem flag, turning every file into a miss regardless of
# actual source changes. Tradeoff: only the component you're
# building gets cross-build ccache hits; dependencies fall back
# to plain store substitution.
{ system, target }:
let
  pkgs = inputs.nix.inputs.nixpkgs.legacyPackages.${system};
  scope =
    (inputs.nix.lib.makeComponents {
      inherit pkgs;
      getStdenv = p: p.ccacheStdenv;
    }).overrideScope
      (
        finalScope: prevScope: {
          withUnityBuild = false;
          nix-store = prevScope.nix-store.override { withAWS = false; };
        }
      );

  # random_seed: stdenv's cc-wrapper adds a fresh -frandom-seed
  # every invocation, a guaranteed miss otherwise.
  # include_file_mtime/ctime: every dependency header is
  # materialized fresh each build, which ccache's own "recently
  # modified" safety check would otherwise reject.
  ccacheTuning = ''
    export CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime
    export CCACHE_COMPRESS=1
    export CCACHE_UMASK=007
  '';
in
scope.overrideAllMesonComponents (
  finalAttrs: prevAttrs:
  if prevAttrs.pname == target then
    let
      inc = mkIncremental {
        name = prevAttrs.pname;
        inherit system;
        cacheVars = [ "CCACHE_DIR" ];
        nuke = false;
        keepIncremental = true;
      };
      env = ccacheEnv {
        inherit pkgs;
        pname = prevAttrs.pname;
        dir = inc.dir;
        debugDir = inc.debugDir;
      };
    in
    {
      outputs = (prevAttrs.outputs or [ "out" ]) ++ inc.outputs;
      # Meson resolves CMake deps (e.g. nix-expr's toml11) during
      # configurePhase, so CCACHE_DIR must be live before that.
      preConfigure = (prevAttrs.preConfigure or "") + inc.restore + env.setup;
      postInstall = (prevAttrs.postInstall or "") + env.report;
    }
  else
    {
      preConfigure =
        (prevAttrs.preConfigure or "")
        + ''
          mkdir -p "$NIX_BUILD_TOP/ccache-scratch"
          export CCACHE_DIR="$NIX_BUILD_TOP/ccache-scratch"
        ''
        + ccacheTuning;
    }
)
