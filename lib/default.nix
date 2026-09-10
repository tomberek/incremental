{ inputs }:
let
  lib = inputs.nixpkgs.lib;

  resolveCache = import ./resolve-cache.nix;
  mkIncremental = import ./mk-incremental.nix { inherit inputs lib; };
  mkIncrementalPackage = import ./mk-incremental-package.nix {
    inherit
      inputs
      lib
      mkIncremental
      resolveCache
      ;
  };
  mkIncrementalAutotoolsPackage = import ./mk-incremental-autotools-package.nix {
    inherit inputs mkIncrementalPackage;
  };
  mkEcosystemPackage = import ./mk-ecosystem-package.nix { inherit inputs mkIncrementalPackage; };
  mkIncrementalGoPackage = import ./mk-incremental-go-package.nix { inherit mkEcosystemPackage; };
  mkIncrementalZigPackage = import ./mk-incremental-zig-package.nix { inherit mkEcosystemPackage; };
  mkIncrementalRustPackage = import ./mk-incremental-rust-package.nix {
    inherit
      inputs
      mkIncremental
      mkIncrementalPackage
      resolveCache
      ;
  };
  ccacheEnv = import ./ccache-env.nix;
  mkIncrementalCcachePackage = import ./mk-incremental-ccache-package.nix {
    inherit
      inputs
      lib
      mkIncremental
      mkIncrementalPackage
      ccacheEnv
      resolveCache
      ;
  };
  mkIncrementalCcacheAutotoolsPackage = import ./mk-incremental-ccache-autotools-package.nix {
    inherit
      inputs
      lib
      mkIncremental
      mkIncrementalAutotoolsPackage
      ccacheEnv
      resolveCache
      ;
  };
  mkIncrementalNixComponents = import ./mk-incremental-nix-components.nix {
    inherit inputs mkIncremental ccacheEnv;
  };
in
{
  inherit
    mkIncremental
    mkIncrementalPackage
    mkIncrementalAutotoolsPackage
    mkIncrementalGoPackage
    mkIncrementalZigPackage
    mkIncrementalRustPackage
    ccacheEnv
    mkIncrementalCcachePackage
    mkIncrementalCcacheAutotoolsPackage
    mkIncrementalNixComponents
    ;
}
