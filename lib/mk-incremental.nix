{
  inputs,
  lib,
  mkIncrementalData,
  mkWithCache,
  mkAsCacheApp,
}:
let
  # `phase` is whichever hook runs before the tool reads its cache dir.
  # Required: e.g. buildGoModule's own configurePhase sets $GOCACHE and
  # only then runs postConfigure, so golang needs that specific hook.
  mkIncremental =
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
      inc = mkIncrementalData {
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
        # nuke-refs isn't on stdenv's PATH by default. Unconditional
        # now (not gated by `nuke`, unlike below): mkIncrementalData's
        # nukeScript always nuke-refs's debugDir, regardless of `nuke`
        # — see its own comment for why that pass can't be optional.
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.nukeReferences ];
        # nuke-refs's debugDir pass has to run after *everything* that
        # can still write to it, not just after installPhase.
        # nixpkgs' own phase order is installPhase -> fixupPhase ->
        # installCheckPhase -> distPhase -> postPhases (confirmed via
        # setup.sh's definePhases) — a package with `doCheck`/
        # `doInstallCheck` (nixpkgs-jq, nixpkgs-python3, ...) runs its
        # test suite in installCheckPhase, *after* postInstall, and
        # ccache's own debug logging captures every compile that test
        # suite triggers. Attaching to postInstall (as this used to)
        # nuked too early: confirmed directly on nixpkgs-jq, real
        # un-nuked store-path hashes from files written during
        # installCheckPhase's `make check` survived a postInstall nuke
        # pass. postPhases is a list of *phase names*, run last of
        # all — genericBuild's runPhase evaluates the same-named shell
        # variable if one is set (setup.sh: `eval
        # "${!curPhase:-$curPhase}"`), so nukeDebugLogsPhase below is
        # both the phase name and its own script.
        postPhases = (old.postPhases or [ ]) ++ [ "nukeDebugLogsPhase" ];
        nukeDebugLogsPhase = (old.nukeDebugLogsPhase or "") + inc.nukeScript;
        # Restores from a build of a third party's own without touching
        # their flake inputs: `pkg.withCache "git+file://...?rev=<sha>"`.
        passthru = (old.passthru or { }) // {
          withCache = mkWithCache mkIncremental args inc.keepIncremental;
          asCacheApp = mkAsCacheApp { inherit inputs pkgs name; };
        };
      }
      // {
        postInstall = (old.postInstall or "") + extraPostInstall inc.isCached;
      }
    );
in
mkIncremental
