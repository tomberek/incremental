# Pinned toolchain for nixgg.
#
# Everything the shim drivers and nix/{builder,linker,archiver}.nix
# need is realised from THIS flake, not the ambient <nixpkgs>. That
# makes every CA derivation reproducible across machines and time —
# flake.lock is the single source of truth.
{
  description = "nixgg — gg-style build accelerator using Nix CA derivations.";

  # Auto-enable the experimental features mkNixggBuild needs. Users
  # still get prompted the first time they build (Nix asks before
  # trusting a flake's nixConfig), but after that
  # `nix build .#hello` / `.#lua` Just Works.
  nixConfig = {
    extra-experimental-features = [
      "ca-derivations"
      "dynamic-derivations"
      "configurable-impure-env"
    ];
    extra-system-features = [ "builder-rpc-v0" ];
  };

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
            gnumake = pkgs.gnumake;
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
          # under pure-eval mode. We also generate toolchain.nix
          # alongside them with the pinned compiler/bash/coreutils
          # roots, so every thunk can `import ./toolchain.nix` instead
          # of duplicating those store paths inline.
          nixHelpers = pkgs.runCommand "nixgg-nix" { } ''
            cp -r ${./nix} $out
            chmod -R u+w $out
            cat > $out/toolchain.nix <<'EOF'
            # Toolchain paths pinned by nixgg's flake.lock. Every thunk
            # imports this file rather than duplicating the store paths
            # in its own body — shrinks thunks, and toolchain rev-bumps
            # only touch this file's content-hash.
            {
              compilerRoot  = "${toolchain.gcc}";
              bashRoot      = "${toolchain.bash}";
              coreutilsRoot = "${toolchain.coreutils}";
            }
            EOF
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
              export NIXGG_GNUMAKE_ROOT="${toolchain.gnumake}"
              export NIXGG_REAL_CC="${toolchain.gcc}/bin/g++"
              export NIXGG_NIX="${toolchain.nix}/bin/nix"
              export NIXGG_NIX_HELPERS="${nixHelpers}"
              # PR 15793's nix build. Only needed by `nixgg emit`
              # .sandboxed; every other subcommand ignores it.
              export NIXGG_PATCHED_NIX="${patchedNix}"
              # Store paths the driver may need to copy into an alt store:
              export NIXGG_TOOLCHAIN_PATHS="${toolchain.gcc} ${toolchain.bash} ${toolchain.coreutils} ${toolchain.gnumake} ${toolchain.nix} ${nixHelpers} ${patchedNix}"
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

          # The nixgg Go binary + shims tree, built from THIS repo's
          # source. `mkNixggBuild` (below) pulls this in as a build
          # input so the sandboxed builder can invoke shims.
          #
          # Static (netgo + osusergo) so it works regardless of what
          # the sandbox mounts.
          nixggBin = pkgs.buildGoModule {
            pname = "nixgg";
            version = "0";
            src = builtins.path {
              name = "nixgg-src";
              path = ./.;
              # Skip generated / scratch dirs.
              filter = path: type:
                let base = baseNameOf path; in
                base != "bin" && base != "dyn-drv"
                && !(pkgs.lib.hasPrefix "." base)
                && base != "shims";
            };
            vendorHash = null;  # no deps
            doCheck = false;
            postInstall = ''
              mkdir -p $out/shims
              for t in ar c++ cc g++ gcc ranlib; do
                ln -s ../bin/nixgg $out/shims/$t
              done
            '';
          };

          # mkNixggBuild wraps a user command in a builder-rpc-v0
          # derivation whose output IS a .drv file — the "final link"
          # drv submitted from inside the sandbox. Consumers get the
          # compiled artifact via `builtins.outputOf drv.outPath "out"`.
          mkNixggBuild = import ./nix/mkNixggBuild.nix {
            inherit (pkgs) lib coreutils gnumake bash;
            gcc         = toolchain.gcc;
            nixgg       = nixggBin;
            nixHelpers  = nixHelpers;
            patchedNix  = patchedNix;
            inherit system;
          };

          # Concrete mkNixggBuild call sites, exposed as flake
          # packages so `nix build .#hello` / `.#lua` Just Work. Each
          # is the resolved final artifact — `builtins.outputOf`
          # applied to the outer text-mode drv — so consumers see a
          # normal store path, not a .drv.
          hello = (import ./dyn-drv/hello-mkbuild.nix {
            inherit mkNixggBuild;
            inherit (pkgs) runCommand;
          }).result;

          lua = (import ./dyn-drv/lua-mkbuild.nix {
            inherit mkNixggBuild;
            inherit (pkgs) fetchurl stdenv;
          }).result;
        in
        toolchain
        // {
          toolchain-json = toolchainJson;
          env-shell = envShell;
          mosh-env = moshEnv;
          fmt-env = fmtEnv;
          patched-nix = patchedNix;
          nixgg-bin = nixggBin;
          # mkNixggBuild is a function; expose so consumers can build
          # their own targets in downstream flakes.
          inherit mkNixggBuild;
          inherit hello lua;
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
