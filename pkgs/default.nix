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
    mkIncrementalHaskellPackage
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
  haskell = import ./haskell.nix { inherit system pkgs mkIncrementalHaskellPackage; };
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
// import ./nixpkgs-kubernetes.nix {
  inherit system pkgs mkIncrementalGoPackage;
}
// import ./nixpkgs-nushell.nix {
  inherit system pkgs mkIncrementalRustPackage;
}
