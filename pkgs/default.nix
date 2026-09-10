{
  inputs,
  lib,
  system,
  pkgs,
  incrementalLib,
}:
let
  inherit (incrementalLib)
    mkIncrementalAutotoolsPackage
    mkIncrementalGoPackage
    mkIncrementalCcachePackage
    mkIncrementalCcacheAutotoolsPackage
    mkIncrementalZigPackage
    mkIncrementalRustPackage
    mkIncrementalNixComponents
    ccacheEnv
    ;
in
{
  hello-ccache = import ./hello-ccache.nix {
    inherit
      system
      pkgs
      mkIncrementalCcacheAutotoolsPackage
      ;
  };
  golang = import ./golang.nix { inherit system pkgs mkIncrementalGoPackage; };
  c = import ./c.nix { inherit system pkgs mkIncrementalCcachePackage; };
  zig = import ./zig.nix { inherit system pkgs mkIncrementalZigPackage; };
  rust = import ./rust.nix { inherit system pkgs mkIncrementalRustPackage; };
}
// import ./nixpkgs-examples.nix {
  inherit
    system
    pkgs
    mkIncrementalCcacheAutotoolsPackage
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
