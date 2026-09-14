{
  lib,
  system,
  pkgs,
  incrementalLib,
}:
let
  inherit (incrementalLib)
    mkIncrementalGoPackage
    mkIncrementalCcachePackage
    mkIncrementalZigPackage
    mkIncrementalSwiftPackage
    mkIncrementalRustPackage
    mkIncrementalNixComponents
    ;
in
{
  hello-ccache = import ./hello-ccache.nix {
    inherit
      system
      pkgs
      mkIncrementalCcachePackage
      ;
  };
  golang = import ./golang.nix { inherit system pkgs mkIncrementalGoPackage; };
  c = import ./c.nix { inherit system pkgs mkIncrementalCcachePackage; };
  zig = import ./zig.nix { inherit system pkgs mkIncrementalZigPackage; };
  swift = import ./swift.nix { inherit system pkgs mkIncrementalSwiftPackage; };
  rust = import ./rust.nix { inherit system pkgs mkIncrementalRustPackage; };
}
// import ./nixpkgs-examples.nix {
  inherit
    lib
    system
    pkgs
    mkIncrementalCcachePackage
    ;
}
// import ./nix-components.nix {
  inherit
    lib
    pkgs
    system
    mkIncrementalNixComponents
    ;
}
