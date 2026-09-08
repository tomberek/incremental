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
      # Wraps `nix build --expr '(builtins.getFlake ...).<attrpath>.withCache "<cacheRef>"'`
      # for a third party without --impure or editing their own flake.nix.
      # A bare `<flake-ref>#name` (no dots) expands to
      # `packages.<system>.name`; a dotted path is used as given.
      apps = builtins.mapAttrs (system: pkgs: {
        with-cache = {
          type = "app";
          program = "${pkgs.writeShellScript "with-cache" ''
            set -euo pipefail
            if [ "$#" -lt 2 ]; then
              echo "usage: with-cache <flake-ref>#<name-or-attrpath> <cache-flake-ref> [nix build args...]" >&2
              exit 1
            fi
            target="$1"; cacheRef="$2"; shift 2
            flakeRef="''${target%%#*}"
            attrPathStr="''${target#*#}"
            if [ "$flakeRef" = "$target" ]; then
              echo "error: target must be <flake-ref>#<name-or-attrpath>" >&2
              exit 1
            fi
            case "$attrPathStr" in
              *.*) ;; # already a full attrpath, e.g. checks.x86_64-linux.foo
              *)
                system=$(${pkgs.nix}/bin/nix eval --impure --raw --expr builtins.currentSystem)
                attrPathStr="packages.$system.$attrPathStr"
                ;;
            esac
            IFS='.' read -r -a parts <<< "$attrPathStr"
            nixList="["
            for p in "''${parts[@]}"; do nixList+=" \"$p\""; done
            nixList+=" ]"
            expr="let pkg = builtins.foldl' (acc: a: acc.\''${a}) (builtins.getFlake \"$flakeRef\") $nixList; in pkg.withCache \"$cacheRef\""
            log=$(mktemp)
            trap 'rm -f "$log"' EXIT
            set +e
            ${pkgs.nix}/bin/nix build --expr "$expr" "$@" 2> >(tee "$log" >&2)
            status=$?
            set -e
            if [ "$status" -ne 0 ] && grep -q "unlocked flake reference" "$log"; then
              echo "" >&2
              echo "hint: withCache needs a rev-pinned ref, e.g. add ?rev=\$(git -C <repo> rev-parse HEAD) to whichever ref above is unlocked." >&2
            fi
            exit "$status"
          ''}";
        };
        # Same script as scripts/build-with-cache.sh, runnable without a checkout.
        build-with-cache = {
          type = "app";
          program = "${pkgs.writeShellApplication {
            name = "build-with-cache";
            runtimeInputs = [ pkgs.nix ];
            text = builtins.readFile ./scripts/build-with-cache.sh;
          }}/bin/build-with-cache";
        };
        # Same script as scripts/build-input-diff.sh, runnable without a checkout.
        build-input-diff = {
          type = "app";
          program = "${pkgs.writeShellApplication {
            name = "build-input-diff";
            runtimeInputs = [ pkgs.nix ];
            text = builtins.readFile ./scripts/build-input-diff.sh;
          }}/bin/build-input-diff";
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
