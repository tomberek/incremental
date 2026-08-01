# Pinned toolchain for nixgg.
#
# Everything the shim drivers and nix/{builder,linker,archiver}.nix
# need is realised from THIS flake, not the ambient <nixpkgs>. That
# makes every CA derivation reproducible across machines and time —
# flake.lock is the single source of truth.
{
  description = "nixgg — gg-style build accelerator using Nix CA derivations.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # PR 15793 (NixOS/nix#15793) — adds the limited daemon socket inside
  # builder-rpc-v0 sandboxes plus the `nix store submit-output`
  # command. Only used by `nixgg emit`'s `.sandboxed` variant.
  #
  # The PR is closed (not merged), so its head commit isn't on a
  # branch of NixOS/nix. GitHub keeps `refs/pull/<N>/head` for every
  # PR forever, so we fetch that ref via git+https. This works even
  # if the fork is later deleted.
  inputs.nix-15793 = {
    url = "git+https://github.com/NixOS/nix.git?ref=refs/pull/15793/head";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, nix-15793 }:
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

          # Nix built from PR 15793 (builder-rpc-v0 / submit-output).
          # Only used by `nixgg emit`'s .sandboxed variant. `patched-nix`
          # follows the same flake schema as upstream, so its default
          # package is the nix CLI.
          patchedNix =
            (nix-15793.packages.${system}.nix-cli
              or nix-15793.packages.${system}.default);

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
              patched_nix = "${patchedNix}";
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
              # PR 15793's nix build. Only needed by `nixgg emit`
              # .sandboxed; every other subcommand ignores it.
              export NIXGG_PATCHED_NIX="${patchedNix}"
              # Store paths the driver may need to copy into an alt store:
              export NIXGG_TOOLCHAIN_PATHS="${toolchain.gcc} ${toolchain.bash} ${toolchain.coreutils} ${toolchain.nix} ${nixHelpers} ${patchedNix}"
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

          fmtEnv = pkgs.stdenv.mkDerivation {
            name = "nixgg-fmt-env";
            nativeBuildInputs = with pkgs; [
              cmake ninja gnumake pkg-config which
            ];
            dontUnpack = true;
            installPhase = "mkdir -p $out";
          };
        in
        toolchain
        // {
          toolchain-json = toolchainJson;
          env-shell = envShell;
          mosh-env = moshEnv;
          fmt-env = fmtEnv;
          patched-nix = patchedNix;
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
