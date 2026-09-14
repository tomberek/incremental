{ inputs }:
let
  lib = inputs.nixpkgs.lib;

  mkWithCache = import ./mk-with-cache.nix;
  mkAsCacheApp = import ./mk-as-cache-app.nix;
  mkIncrementalData = import ./mk-incremental-data.nix { inherit inputs lib; };
  mkIncremental = import ./mk-incremental.nix {
    inherit
      inputs
      lib
      mkIncrementalData
      mkWithCache
      mkAsCacheApp
      ;
  };
  mkIncrementalAutotoolsPackage = import ./mk-incremental-autotools-package.nix {
    inherit inputs mkIncremental;
  };
  mkEcosystemPackage = import ./mk-ecosystem-package.nix { inherit inputs mkIncremental; };
  mkIncrementalGoPackage = import ./mk-incremental-go-package.nix { inherit mkEcosystemPackage; };
  mkIncrementalZigPackage = import ./mk-incremental-zig-package.nix { inherit mkEcosystemPackage; };
  mkIncrementalSwiftPackage = import ./mk-incremental-swift-package.nix {
    inherit mkEcosystemPackage;
  };
  mkIncrementalRustPackage = import ./mk-incremental-rust-package.nix {
    inherit
      inputs
      mkIncrementalData
      mkIncremental
      mkWithCache
      ;
  };
  mkIncrementalHaskellPackage = import ./mk-incremental-haskell-package.nix {
    inherit inputs mkWithCache mkAsCacheApp;
  };
  ccacheEnv = import ./ccache-env.nix;
  mkIncrementalCcachePackage = import ./mk-incremental-ccache-package.nix {
    inherit
      inputs
      lib
      mkIncrementalData
      mkIncremental
      mkIncrementalAutotoolsPackage
      mkWithCache
      ccacheEnv
      ;
  };
  mkIncrementalNixComponents = import ./mk-incremental-nix-components.nix {
    inherit inputs mkIncrementalData ccacheEnv;
  };
in
{
  inherit
    mkIncremental
    mkIncrementalAutotoolsPackage
    mkIncrementalGoPackage
    mkIncrementalZigPackage
    mkIncrementalSwiftPackage
    mkIncrementalRustPackage
    mkIncrementalHaskellPackage
    ccacheEnv
    mkIncrementalCcachePackage
    mkIncrementalNixComponents
    ;
}
