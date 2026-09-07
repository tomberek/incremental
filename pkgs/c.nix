{
  system,
  pkgs,
  mkIncrementalCcachePackage,
}:
# Worked example for mkIncrementalCcachePackage: plain C, no build system.
mkIncrementalCcachePackage {
  name = "c";
  inherit system pkgs;
  phase = "postPatch"; # dontConfigure skips configurePhase, so preConfigure would too
  drv = pkgs.ccacheStdenv.mkDerivation {
    name = "c";
    src = pkgs.lib.cleanSource ../c;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      $CC -c a.c -o a.o
      $CC -c b.c -o b.o
      $CC -c main.c -o main.o
      $CC a.o b.o main.o -o c
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp c $out/bin/
      runHook postInstall
    '';
  };
}
