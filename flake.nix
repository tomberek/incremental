{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.nix.url = "github:NixOS/nix";

  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;

      incrementalLib = import ./lib { inherit inputs; };
    in
    {
      lib = incrementalLib;
      formatter = builtins.mapAttrs (system: pkgs: pkgs.nixfmt-tree) inputs.nixpkgs.legacyPackages;
      devShells = builtins.mapAttrs (system: pkgs: rec {
        default = pkgs.mkShell {
          name = "dev-shell";
          inputsFrom = builtins.attrValues inputs.self.packages.${system};
        };
      }) inputs.nixpkgs.legacyPackages;
      # Wraps `nix build --expr '(builtins.getFlake ...).<attrpath>.withCache "<baselineRef>"'`
      # for a third party without --impure or editing their own flake.nix.
      # A bare `<flake-ref>#name` (no dots) expands to
      # `packages.<system>.name`; a dotted path is used as given.
      apps = builtins.mapAttrs (system: pkgs: {
        with-cache = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "with-cache";
              runtimeInputs = [
                pkgs.nix
                pkgs.jq
              ];
              text = builtins.readFile ./scripts/with-cache.sh;
            }
          }/bin/with-cache";
        };
        # Same script as scripts/build-with-cache.sh, runnable without a checkout.
        build-with-cache = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "build-with-cache";
              runtimeInputs = [ pkgs.nix ];
              text = builtins.readFile ./scripts/build-with-cache.sh;
            }
          }/bin/build-with-cache";
        };
        # Same script as scripts/build-input-diff.sh, runnable without a checkout.
        build-input-diff = {
          type = "app";
          program = "${
            pkgs.writeShellApplication {
              name = "build-input-diff";
              runtimeInputs = [ pkgs.nix ];
              text = builtins.readFile ./scripts/build-input-diff.sh;
            }
          }/bin/build-input-diff";
        };
      }) inputs.nixpkgs.legacyPackages;
      packages = builtins.mapAttrs (
        system: pkgs:
        import ./pkgs {
          inherit
            inputs
            lib
            system
            pkgs
            incrementalLib
            ;
        }
      ) inputs.nixpkgs.legacyPackages;
      # Self-tests for the caching mechanism itself — see README, "Checks".
      checks = builtins.mapAttrs (
        system: pkgs:
        import ./checks {
          inherit
            inputs
            system
            pkgs
            incrementalLib
            ;
        }
      ) inputs.nixpkgs.legacyPackages;
    };
}
