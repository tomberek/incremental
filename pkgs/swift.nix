{
  system,
  pkgs,
  mkIncrementalSwiftPackage,
}:
mkIncrementalSwiftPackage {
  name = "swift";
  inherit system pkgs;
  drv = pkgs.stdenv.mkDerivation {
    name = "swift";
    src = pkgs.lib.cleanSource ../swift;
    nativeBuildInputs = [
      pkgs.swift
      pkgs.swiftpm
      pkgs.makeWrapper
    ];
    buildInputs = [ pkgs.swiftPackages.Foundation ];
    env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.swiftPackages.Dispatch ];
    buildPhase = ''
      runHook preBuild
      swift build --scratch-path "$SWIFTPM_SCRATCH_PATH" -c release
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp "$(swift build --scratch-path "$SWIFTPM_SCRATCH_PATH" -c release --show-bin-path)/swift-example" $out/bin/
      wrapProgram $out/bin/swift-example --set LD_LIBRARY_PATH "$LD_LIBRARY_PATH"
      runHook postInstall
    '';
  };
}
