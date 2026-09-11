{
  inputs,
  mkIncremental,
  mkIncrementalPackage,
  mkWithCache,
}:
let
  # buildRustPackage's cargoInstallHook looks for a fixed *relative*
  # path (`target/<subdir>/<buildType>`), not $CARGO_TARGET_DIR — so
  # unlike Go/Zig, the restored dir has to be symlinked to `./target`
  # rather than exported as an env var. cargoBuildHook's `runHook
  # preBuild` (right before `cargo build`) is still the right point
  # to do that, before anything reads the target dir.
  mkIncrementalRustPackage =
    args@{
      name,
      system,
      pkgs,
      drv,
      cache ? inputs.cache,
      nuke ? true,
      keepIncremental ? !(cache ? packages),
      extraPostInstall ? (_: ""),
    }:
    let
      inc = mkIncremental {
        inherit
          name
          system
          cache
          nuke
          keepIncremental
          ;
        cacheVars = [ ];
      };
    in
    (mkIncrementalPackage {
      inherit
        name
        system
        pkgs
        drv
        cache
        nuke
        keepIncremental
        extraPostInstall
        ;
      cacheVars = [ ];
      phase = "preBuild";
    }).overrideAttrs
      (old: {
        preBuild = old.preBuild + "ln -sfn ${inc.dir} target\n";
        passthru = old.passthru // {
          withCache = mkWithCache mkIncrementalRustPackage args inc.keepIncremental;
        };
      });
in
mkIncrementalRustPackage
