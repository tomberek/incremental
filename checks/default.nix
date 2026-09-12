{
  inputs,
  system,
  pkgs,
  incrementalLib,
}:
let
  inherit (incrementalLib)
    mkIncremental
    mkIncrementalRustPackage
    ;
in
{
  c-self-test = import ./c-self-test.nix { inherit inputs system; };
  nuke-refs-self-test = import ./nuke-refs-self-test.nix {
    inherit system pkgs mkIncremental;
  };
  rust-staleness-self-test = import ./rust-staleness-self-test.nix {
    inherit
      inputs
      system
      pkgs
      mkIncrementalRustPackage
      ;
  };
}
