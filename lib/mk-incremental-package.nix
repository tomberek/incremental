{
  inputs,
  lib,
  mkIncremental,
  mkWithCache,
  mkAsCacheApp,
}:
let
  # `phase` is whichever hook runs before the tool reads its cache dir.
  # Required: e.g. buildGoModule's own configurePhase sets $GOCACHE and
  # only then runs postConfigure, so golang needs that specific hook.
  mkIncrementalPackage =
    args@{
      name,
      system,
      cacheVars,
      drv,
      phase,
      pkgs, # nuke-refs comes from here
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
          cacheVars
          cache
          nuke
          keepIncremental
          ;
      };
    in
    drv.overrideAttrs (
      old:
      {
        outputs = (old.outputs or [ "out" ]) ++ inc.outputs;
        ${phase} = (old.${phase} or "") + inc.restore;
        # nuke-refs isn't on stdenv's PATH by default — added here so
        # callers can't forget it and hit "command not found" the one
        # time `nuke` actually fires (e.g. once keepIncremental flips).
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ lib.optional nuke pkgs.nukeReferences;
        # Restores from a build of a third party's own without touching
        # their flake inputs: `pkg.withCache "git+file://...?rev=<sha>"`.
        passthru = (old.passthru or { }) // {
          withCache = mkWithCache mkIncrementalPackage args inc.keepIncremental;
          asCacheApp = mkAsCacheApp { inherit inputs pkgs name; };
        };
      }
      // lib.optionalAttrs (nuke || (extraPostInstall inc.isCached) != "") {
        postInstall = (old.postInstall or "") + inc.nukeScript + extraPostInstall inc.isCached;
      }
    );
in
mkIncrementalPackage
