{
  inputs,
  mkWithCache,
  mkAsCacheApp,
}:

# Unlike every other ecosystem here, nixpkgs' own Haskell builder
# (pkgs/development/haskell-modules/generic-builder.nix) already has
# a first-class incremental-build mechanism: pass `previousIntermediates`
# (a prior build's `intermediates` output) and it splices
# `${previousIntermediates}/${intermediatesDir}/build` into `dist/build`
# in `buildPhase`, before Cabal/GHC's own (content- and mtime-based,
# but Nix-normalized-mtime-safe — confirmed empirically, unlike Cargo)
# recompilation-avoidance decides what's stale. So there's no restore
# script or ccache-style external tool state to nuke-refs here — this
# just has to turn that mechanism on and pass the prior build through.
#
# `doInstallIntermediates`/`enableSeparateIntermediatesOutput` must be
# constructor args to `mkDerivation`, not `.overrideAttrs` — the
# `installIntermediatesPhase` and the "intermediates" entry in
# `outputs` are both computed once, inside generic-builder.nix's own
# `let`, before the final attrset is built; `overrideAttrs` runs too
# late to add either (confirmed: silently produces zero "intermediates"
# output with a plain `.overrideAttrs`). `haskell.lib.compose.overrideCabal`
# intercepts the `mkDerivation` call itself, so it's the right layer —
# works on any `haskellPackages.*` derivation, not just ones built from
# scratch here.
let
  mkIncrementalHaskellPackage =
    args@{
      name,
      system,
      pkgs,
      drv,
      cache ? inputs.cache,
      keepIncremental ? !(cache ? packages),
    }:
    let
      prevIntermediates = cache.packages.${system}.${name}.intermediates or null;
    in
    (pkgs.haskell.lib.compose.overrideCabal (_old: {
      doInstallIntermediates = true;
      enableSeparateIntermediatesOutput = keepIncremental;
      previousIntermediates = prevIntermediates;
    }) drv).overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          withCache = mkWithCache mkIncrementalHaskellPackage args keepIncremental;
          asCacheApp = mkAsCacheApp { inherit inputs pkgs name; };
        };
      });
in
mkIncrementalHaskellPackage
