# Pinned toolchain for nixgg.
#
# Everything the shim drivers and nix/{builder,linker,archiver}.nix
# need is realised from THIS flake, not the ambient <nixpkgs>. That
# makes every CA derivation reproducible across machines and time —
# flake.lock is the single source of truth.
{
  description = "nixgg — gg-style build accelerator using Nix CA derivations.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forEachSystem = f: builtins.mapAttrs (system: pkgs: f system pkgs) nixpkgs.legacyPackages;
    in
    {
      packages = forEachSystem (
        system: pkgs:
        let
          toolchain = {
            gcc = pkgs.gcc;
            bash = pkgs.bash;
            coreutils = pkgs.coreutils;
            nix = pkgs.nixVersions.stable;
          };

          # The nix/ helper directory (builder.nix, linker.nix,
          # archiver.nix, pure-store-path.nix) imported into the store
          # once so drivers can `import` them by absolute store path
          # under pure-eval mode.
          nixHelpers = pkgs.runCommand "nixgg-nix" { } ''
            cp -r ${./nix} $out
          '';

          toolchainJson = pkgs.writeTextFile {
            name = "nixgg-toolchain.json";
            text = builtins.toJSON {
              gcc = "${toolchain.gcc}";
              bash = "${toolchain.bash}";
              coreutils = "${toolchain.coreutils}";
              nix = "${toolchain.nix}";
              real_cc = "${toolchain.gcc}/bin/g++";
              nix_helpers = "${nixHelpers}";
            };
          };

          # Bash-sourceable env block. `. $(nix build .#env-shell --print-out-paths)`
          # sets every NIXGG_* variable the driver needs, with no jq / python /
          # eval required by the consumer.
          envShell = pkgs.writeTextFile {
            name = "nixgg-env.sh";
            executable = false;
            text = ''
              # nixgg toolchain env, pinned by flake.lock. Source this file.
              export NIXGG_COMPILER_ROOT="${toolchain.gcc}"
              export NIXGG_BASH_ROOT="${toolchain.bash}"
              export NIXGG_COREUTILS_ROOT="${toolchain.coreutils}"
              export NIXGG_REAL_CC="${toolchain.gcc}/bin/g++"
              export NIXGG_NIX="${toolchain.nix}/bin/nix"
              export NIXGG_NIX_HELPERS="${nixHelpers}"
              # Store paths the driver may need to copy into an alt store:
              export NIXGG_TOOLCHAIN_PATHS="${toolchain.gcc} ${toolchain.bash} ${toolchain.coreutils} ${toolchain.nix} ${nixHelpers}"
            '';
          };

          moshEnv = pkgs.stdenv.mkDerivation {
            name = "nixgg-mosh-env";
            nativeBuildInputs = with pkgs; [
              autoconf automake libtool pkg-config perl gnumake protobuf which
            ];
            buildInputs = with pkgs; [ ncurses openssl zlib protobuf ];
            dontUnpack = true;
            installPhase = "mkdir -p $out";
          };
        in
        toolchain
        // {
          toolchain-json = toolchainJson;
          env-shell = envShell;
          mosh-env = moshEnv;
          default = envShell;
        }
      );

      devShells = forEachSystem (system: pkgs: {
        default = self.packages.${system}.mosh-env;
      });

      apps = forEachSystem (system: pkgs: {
        nixgg = {
          type = "app";
          program = "${./nixgg}";
        };
        default = {
          type = "app";
          program = "${./nixgg}";
        };
      });
    };
}
