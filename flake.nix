{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.nix.url = "github:NixOS/nix";

  outputs =
    inputs:
    let
      lib = inputs.nixpkgs.lib;

      incrementalLib = import ./lib { inherit inputs; };
      inherit (incrementalLib)
        mkIncremental
        mkIncrementalPackage
        mkIncrementalAutotoolsPackage
        mkIncrementalGoPackage
        mkIncrementalZigPackage
        mkIncrementalRustPackage
        ccacheEnv
        mkIncrementalCcachePackage
        mkIncrementalNixComponents
        ;
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
      }) inputs.nixpkgs.legacyPackages;
      packages = builtins.mapAttrs (
        system: pkgs:
        let
          nixComponentNames = [
            "nix-util"
            "nix-util-c"
            "nix-store"
            "nix-store-c"
            "nix-fetchers"
            "nix-fetchers-c"
            "nix-expr"
            "nix-expr-c"
            "nix-flake"
            "nix-flake-c"
            "nix-main"
            "nix-main-c"
            "nix-cmd"
          ];
        in
        {
          hello-ccache =
            let
              mkHelloCcache =
                cache:
                let
                  env = ccacheEnv {
                    inherit pkgs;
                    pname = "hello-ccache";
                    dir = "$incremental";
                    debugDir = "$incremental/debug-logs";
                  };
                in
                (mkIncrementalAutotoolsPackage {
                  name = "hello-ccache";
                  inherit system cache pkgs;
                  cacheVars = [ "CCACHE_DIR" ];
                  drv = pkgs.hello.override { stdenv = pkgs.ccacheStdenv; };
                  extraPostInstall = _isCached: env.report;
                }).overrideAttrs
                  (old: {
                    postPatch = old.postPatch + env.setup;
                    # Overrides the inherited passthru.withCache from
                    # mkIncrementalPackage, which would skip env.setup above.
                    passthru = old.passthru // {
                      withCache =
                        cacheFlake:
                        mkHelloCcache (if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake);
                    };
                  });
            in
            mkHelloCcache inputs.cache;

          golang = mkIncrementalGoPackage {
            name = "golang";
            inherit system pkgs;
            drv = pkgs.buildGoModule {
              name = "golang";
              src = pkgs.lib.cleanSource ./golang;
              vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
            };
          };

          # Worked example for mkIncrementalCcachePackage: plain C, no build system.
          c = mkIncrementalCcachePackage {
            name = "c";
            inherit system pkgs;
            phase = "postPatch"; # dontConfigure skips configurePhase, so preConfigure would too
            drv = pkgs.ccacheStdenv.mkDerivation {
              name = "c";
              src = pkgs.lib.cleanSource ./c;
              dontConfigure = true;
              buildPhase = ''
                runHook preBuild
                $CC -c a.c -o a.o
                $CC -c b.c -o b.o
                $CC -c main.c -o main.o
                $CC a.o b.o main.o -o c
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                mkdir -p $out/bin
                cp c $out/bin/
                runHook postInstall
              '';
            };
          };

          zig = mkIncrementalZigPackage {
            name = "zig";
            inherit system pkgs;
            drv = pkgs.stdenvNoCC.mkDerivation {
              name = "zig";
              src = pkgs.lib.cleanSource ./zig;
              nativeBuildInputs = [ pkgs.zig.hook ];
            };
          };

          rust = mkIncrementalRustPackage {
            name = "rust";
            inherit system pkgs;
            drv = pkgs.rustPlatform.buildRustPackage {
              name = "rust";
              src = pkgs.lib.cleanSource ./rust;
              cargoLock = {
                lockFile = ./rust/Cargo.lock;
              };
              # Nix normalizes unpacked source mtimes to the epoch, so
              # Cargo's mtime-based fingerprinting sees "unchanged" every
              # rebuild and serves a stale binary. checksum-freshness
              # switches it to content-hash staleness (ccache's own fix,
              # same reason) — unstable, needs RUSTC_BOOTSTRAP on stable.
              env.RUSTC_BOOTSTRAP = "1";
              cargoBuildFlags = [ "-Zchecksum-freshness" ];
            };
          };

          nix-incremental =
            (mkIncrementalNixComponents {
              inherit system;
              target = "nix-cli";
            }).nix-cli;
        }
        // lib.genAttrs nixComponentNames (
          target: (mkIncrementalNixComponents { inherit system target; }).${target}
        )
      ) inputs.nixpkgs.legacyPackages;
      # Self-tests for the caching mechanism itself — see README, "Checks".
      checks = builtins.mapAttrs (
        system: pkgs:
        let
          coldC = inputs.self.packages.${system}.c;
          coldNukeTest = mkIncrementalPackage {
            name = "nuke-refs-self-test";
            inherit system pkgs;
            cacheVars = [ "REF_CACHE_DIR" ];
            phase = "postPatch";
            # References pkgs.hello on every build, cold or warm — a real
            # store path a leftover restore script can't produce by luck.
            # disallowedReferences makes Nix actually reject a leak instead
            # of silently succeeding, matching what buildGoModule's own
            # toolchain reference check does in practice (see README).
            drv = pkgs.stdenvNoCC.mkDerivation {
              name = "nuke-refs-self-test";
              src = ./.;
              dontUnpack = true;
              disallowedReferences = [ pkgs.hello ];
              installPhase = ''
                runHook preInstall
                mkdir -p $out "$REF_CACHE_DIR/objects"
                echo "${pkgs.hello}" > "$REF_CACHE_DIR/objects/ref-$RANDOM"
                runHook postInstall
              '';
            };
          };
          # Builds the same package from two different sources through the
          # same cache slot and asserts the second binary reflects the
          # second source — see the `rust` package above for why this can
          # go wrong without checksum-freshness.
          mkRustStalenessTest =
            {
              src,
              cache ? inputs.cache,
            }:
            mkIncrementalRustPackage {
              name = "rust-staleness-self-test";
              inherit system pkgs cache;
              drv = pkgs.rustPlatform.buildRustPackage {
                name = "rust-staleness-self-test";
                inherit src;
                cargoLock = {
                  lockFile = "${src}/Cargo.lock";
                };
                env.RUSTC_BOOTSTRAP = "1";
                cargoBuildFlags = [ "-Zchecksum-freshness" ];
                doCheck = false;
              };
            };
          rustSrc =
            text:
            pkgs.runCommand "rust-staleness-src" { } ''
              mkdir -p $out/src
              cp ${./rust/Cargo.lock} $out/Cargo.lock
              cp ${./rust/Cargo.toml} $out/Cargo.toml
              echo 'fn main() { println!("${text}"); }' > $out/src/main.rs
            '';
          coldRustStalenessTest = mkRustStalenessTest { src = rustSrc "cold"; };
        in
        {
          rust-staleness-self-test =
            (mkRustStalenessTest {
              src = rustSrc "warm";
              cache = {
                packages.${system}."rust-staleness-self-test".incremental = coldRustStalenessTest.incremental;
              };
            }).overrideAttrs
              (old: {
                postInstall = old.postInstall + ''
                  out=$($out/bin/rust-example)
                  echo "self-test[rust]: binary printed: $out"
                  if [ "$out" != "warm" ]; then
                    echo "self-test[rust]: FAILED — expected \"warm\", got a stale binary printing \"$out\"" >&2
                    exit 1
                  fi
                '';
              });
          c-self-test =
            (coldC.withCache { packages.${system}.c.incremental = coldC.incremental; }).overrideAttrs
              (old: {
                postInstall = old.postInstall + ''
                  pct=$(cat $incremental/ccache-hit-pct)
                  echo "self-test[c]: $pct% ccache hits restoring an unchanged build"
                  if [ "$pct" -lt 90 ]; then
                    echo "self-test[c]: FAILED — expected near-total hits" >&2
                    exit 1
                  fi
                '';
              });
          nuke-refs-self-test = coldNukeTest.withCache {
            packages.${system}."nuke-refs-self-test".incremental = coldNukeTest.incremental;
          };
        }
      ) inputs.nixpkgs.legacyPackages;
    };
}
