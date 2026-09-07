{
  system,
  pkgs,
  mkIncrementalPackage,
}:
let
  coldNukeTest = mkIncrementalPackage {
    name = "nuke-refs-self-test";
    inherit system pkgs;
    cacheVars = [ "REF_CACHE_DIR" ];
    phase = "postPatch";
    # References pkgs.hello on every build, cold or warm — a real
    # store path a leftover restore script can't produce by luck.
    # disallowedReferences makes Nix actually reject a leak instead
    # of silently succeeding, matching what buildGoModule's own
    # toolchain reference check does in practice (see README).
    drv = pkgs.stdenvNoCC.mkDerivation {
      name = "nuke-refs-self-test";
      src = ../.;
      dontUnpack = true;
      disallowedReferences = [ pkgs.hello ];
      installPhase = ''
        runHook preInstall
        mkdir -p $out "$REF_CACHE_DIR/objects"
        echo "${pkgs.hello}" > "$REF_CACHE_DIR/objects/ref-$RANDOM"
        runHook postInstall
      '';
    };
  };
in
coldNukeTest.withCache {
  packages.${system}."nuke-refs-self-test".incremental = coldNukeTest.incremental;
}
