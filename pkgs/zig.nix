{
  system,
  pkgs,
  mkIncrementalZigPackage,
}:
mkIncrementalZigPackage {
  name = "zig";
  inherit system pkgs;
  drv = pkgs.stdenvNoCC.mkDerivation {
    name = "zig";
    src = pkgs.lib.cleanSource ../zig;
    nativeBuildInputs = [ pkgs.zig.hook ];
  };
}
