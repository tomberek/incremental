{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.nix.url = "github:NixOS/nix";

  outputs = inputs:
    let
      lib = inputs.nixpkgs.lib;

      # Restores a previous build's `incremental` output (from `cache`,
      # normally overridden to an earlier checkout) and exports cacheVars
      # pointing at it.
      #
      # `outputs` always includes "incremental", even when the cache dir
      # lives elsewhere (see keepIncremental) — a varying outputs list
      # changes the derivation hash, which changes every -I/-isystem flag
      # a dependent embeds it in, breaking their caching too.
      #
      # keepIncremental defaults off once already restoring from `cache`,
      # to avoid leaving a redundant cache blob on top of the one just
      # read. Pass `keepIncremental = true` to keep producing a real one.
      mkIncremental =
        {
          name, # key into cache.packages.${system}
          system,
          cacheVars, # env vars to point at the restored cache dir
          cache ? inputs.cache, # an already-fetched flake to restore from
          nuke ? true, # nuke-refs a fresh (uncached) dir
          keepIncremental ? !(cache ? packages),
        }:
        let
          prevIncremental = cache.packages.${system}.${name}.incremental or "empty";
          isCached = cache ? packages;
          dir = if keepIncremental then "$incremental" else "$NIX_BUILD_TOP/incremental-scratch";
          debugDir = "$incremental/debug-logs"; # per-file hit/miss logs, always kept
        in
        {
          inherit
            isCached
            keepIncremental
            dir
            debugDir
            ;
          outputs = [ "incremental" ];
          restore =
            lib.optionalString (!keepIncremental) "mkdir -p $incremental\n"
            + ''
              mkdir -p empty
              cp -r ${prevIncremental} ${dir}
              chmod -R +w ${dir}
              mkdir -p ${debugDir}
            ''
            + lib.concatMapStrings (v: "export ${v}=${dir}\n") cacheVars;
          # Runs even when restoring from a real cache: the build still
          # writes new cache entries during this build on top of the
          # restored ones, and those were never nuked.
          nukeScript = if keepIncremental && nuke then "nuke-refs ${dir}/*/*\n" else "";
        };

      # `phase` is whichever hook runs before the tool reads its cache
      # dir. Required, not defaulted: buildGoModule's own configurePhase
      # sets $GOCACHE and only then runs postConfigure, so golang needs
      # that specific hook.
      mkIncrementalPackage =
        {
          name,
          system,
          cacheVars,
          drv,
          phase,
          pkgs, # nuke-refs comes from here — see nukeScript below
          cache ? inputs.cache,
          nuke ? true,
          keepIncremental ? !(cache ? packages),
          extraPostInstall ? (_: ""),
        }:
        let
          inc = mkIncremental { inherit name system cacheVars cache nuke keepIncremental; };
        in
        drv.overrideAttrs (
          old:
          {
            outputs = (old.outputs or [ "out" ]) ++ inc.outputs;
            ${phase} = (old.${phase} or "") + inc.restore;
            # nuke-refs isn't on stdenv's PATH by default — added here so
            # callers can't forget it and hit "command not found" the one
            # time `nuke` actually fires (e.g. once keepIncremental flips).
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ lib.optional nuke pkgs.nukeReferences;
            # Lets a third party restore from a build of theirs without touching
            # their own flake inputs: `pkg.withCache "git+file://...?rev=<sha>"`.
            # Needs a rev-pinned ref — builtins.getFlake requires locked input
            # under pure eval, same as any flake input resolution. Also
            # accepts an already-fetched flake (an attrset) directly, e.g.
            # from `checks` (see below), where there's no ref to fetch.
            #
            # keepIncremental is carried over explicitly (not re-defaulted) —
            # it must stay fixed regardless of which cache is passed in, same
            # reason `outputs` must stay structurally constant (see above).
            passthru = (old.passthru or { }) // {
              withCache =
                cacheFlake:
                mkIncrementalPackage {
                  inherit
                    name
                    system
                    cacheVars
                    drv
                    phase
                    pkgs
                    nuke
                    extraPostInstall
                    ;
                  keepIncremental = inc.keepIncremental;
                  cache = if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake;
                };
            };
          }
          // lib.optionalAttrs (nuke || (extraPostInstall inc.isCached) != "") {
            postInstall = (old.postInstall or "") + inc.nukeScript + extraPostInstall inc.isCached;
          }
        );

      # Adds autoconf's --cache-file so AC_CHECK_*/AC_TRY_* results
      # survive rebuilds. Never touches config.status/Makefile/config.h —
      # those bake $out into text (and sometimes into the compiled
      # binary), so they're not safe to restore across a source patch.
      # See README, "What's safe to cache".
      mkIncrementalAutotoolsPackage =
        {
          name,
          system,
          drv,
          pkgs,
          cache ? inputs.cache,
          cacheVars ? [ ],
          nuke ? cacheVars == [ ],
          extraPostInstall ? (_: ""),
        }:
        mkIncrementalPackage {
          inherit name system cache cacheVars nuke extraPostInstall pkgs;
          keepIncremental = true; # --cache-file needs a real declared output
          phase = "postPatch";
          drv = drv.overrideAttrs (old: {
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--cache-file=${placeholder "incremental"}/config.cache"
            ];
          });
        };

      # buildGoModule's own configurePhase sets $GOCACHE and only then
      # runs postConfigure — mkIncrementalPackage's `phase` argument must
      # be exactly that hook, so bake it in rather than making every
      # caller rediscover it.
      mkIncrementalGoPackage =
        {
          name,
          system,
          pkgs,
          drv,
          cache ? inputs.cache,
          nuke ? true,
          keepIncremental ? !(cache ? packages),
          extraPostInstall ? (_: ""),
        }:
        mkIncrementalPackage {
          inherit
            name
            system
            pkgs
            drv
            cache
            nuke
            keepIncremental
            extraPostInstall
            ;
          cacheVars = [ "GOCACHE" ];
          phase = "postConfigure";
        };

      # zig.hook's zigConfigurePhase only ever reassigns
      # ZIG_GLOBAL_CACHE_DIR, never ZIG_LOCAL_CACHE_DIR — so both must be
      # exported before configurePhase runs, i.e. in preConfigure.
      mkIncrementalZigPackage =
        {
          name,
          system,
          pkgs,
          drv,
          cache ? inputs.cache,
          nuke ? true,
          keepIncremental ? !(cache ? packages),
          extraPostInstall ? (_: ""),
        }:
        mkIncrementalPackage {
          inherit
            name
            system
            pkgs
            drv
            cache
            nuke
            keepIncremental
            extraPostInstall
            ;
          cacheVars = [
            "ZIG_LOCAL_CACHE_DIR"
            "ZIG_GLOBAL_CACHE_DIR"
          ];
          phase = "preConfigure";
        };

      # buildRustPackage's cargoInstallHook looks for a fixed *relative*
      # path (`target/<subdir>/<buildType>`), not $CARGO_TARGET_DIR — so
      # unlike Go/Zig, the restored dir has to be symlinked to `./target`
      # rather than exported as an env var. cargoBuildHook's `runHook
      # preBuild` (right before `cargo build`) is still the right point
      # to do that, before anything reads the target dir.
      mkIncrementalRustPackage =
        {
          name,
          system,
          pkgs,
          drv,
          cache ? inputs.cache,
          nuke ? true,
          keepIncremental ? !(cache ? packages),
          extraPostInstall ? (_: ""),
        }:
        let
          inc = mkIncremental {
            inherit
              name
              system
              cache
              nuke
              keepIncremental
              ;
            cacheVars = [ ];
          };
        in
        (mkIncrementalPackage {
          inherit
            name
            system
            pkgs
            drv
            cache
            nuke
            keepIncremental
            extraPostInstall
            ;
          cacheVars = [ ];
          phase = "preBuild";
        }).overrideAttrs
          (old: {
            preBuild = old.preBuild + "ln -sfn ${inc.dir} target\n";
            passthru = old.passthru // {
              withCache =
                cacheFlake:
                mkIncrementalRustPackage {
                  inherit
                    name
                    system
                    pkgs
                    drv
                    nuke
                    extraPostInstall
                    ;
                  keepIncremental = inc.keepIncremental;
                  cache = if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake;
                };
            };
          });

      # Shared ccache env/report shell.
      ccacheEnv =
        { pkgs, pname, dir, debugDir }:
        {
          setup = ''
            export CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime
            export CCACHE_COMPRESS=1
            export CCACHE_UMASK=007
            export CCACHE_NOINODECACHE=1
            export CCACHE_DEBUG=1
            export CCACHE_DEBUGDIR="${debugDir}"
            ${pkgs.ccache}/bin/ccache --dir "${dir}" --zero-stats > /dev/null
          '';
          report = ''
            ${pkgs.ccache}/bin/ccache --dir "${dir}" --show-stats
            hits=$(${pkgs.ccache}/bin/ccache --dir "${dir}" --print-stats | awk '$1=="direct_cache_hit"||$1=="preprocessed_cache_hit"{s+=$2}END{print s+0}')
            misses=$(${pkgs.ccache}/bin/ccache --dir "${dir}" --print-stats | awk '$1=="cache_miss"{print $2+0}')
            total=$((hits + misses))
            pct=0
            if [ "$total" -gt 0 ]; then pct=$((hits * 100 / total)); fi
            echo "ccache[${pname}]: $hits/$total hits ($pct%)"
            echo "$pct" > "${dir}/ccache-hit-pct" # read by `checks` — see below
            if [ "$misses" -gt 0 ] && [ -d "${debugDir}" ]; then
              echo "ccache[${pname}]: miss reasons (top):"
              find "${debugDir}" -name '*.ccache-log' -exec grep -m1 "Result:" {} + 2>/dev/null \
                | sed -E 's/^.*Result: //' | sort | uniq -c | sort -rn | head -5 \
                | sed "s/^/ccache[${pname}]:   /" || true
            fi
          '';
        };

      # Add ccache caching to a package: mkIncrementalCcachePackage
      # { name, system, pkgs, drv, phase }. `drv` must already be built
      # with ccacheStdenv (a plain stdenv.mkDerivation has no .override
      # for swapping it in after the fact); the assert below catches a
      # missing ccacheStdenv at eval time instead of a sandbox
      # "Permission denied" during the build.
      #
      # `phase`: same rule as mkIncrementalPackage — use postPatch if the
      # package skips configurePhase (dontConfigure or similar).
      mkIncrementalCcachePackage =
        {
          name,
          system,
          pkgs,
          drv,
          phase,
          cache ? inputs.cache,
          nuke ? false, # ccache manages its own dir
          keepIncremental ? !(cache ? packages),
        }:
        assert lib.assertMsg (drv.stdenv.cc.pname or "" == "ccache-links-wrapper")
          "mkIncrementalCcachePackage: `drv` (${name}) wasn't built with pkgs.ccacheStdenv.";
        let
          inc = mkIncremental {
            inherit
              name
              system
              cache
              nuke
              keepIncremental
              ;
            cacheVars = [ "CCACHE_DIR" ];
          };
          env = ccacheEnv {
            inherit pkgs;
            pname = name;
            dir = inc.dir;
            debugDir = inc.debugDir;
          };
        in
        (mkIncrementalPackage {
          inherit
            name
            system
            drv
            phase
            pkgs
            cache
            nuke
            keepIncremental
            ;
          cacheVars = [ "CCACHE_DIR" ];
          extraPostInstall = _isCached: env.report;
        }).overrideAttrs
          (old: {
            # env.setup needs CCACHE_DIR live, which inc.restore just set
            # in ${phase} — so it has to run after, in one more layer.
            ${phase} = old.${phase} + env.setup;
            # Overrides the inherited passthru.withCache from
            # mkIncrementalPackage — that one skips env.setup, which
            # would silently drop CCACHE_SLOPPINESS/debug-logging/report.
            passthru = old.passthru // {
              withCache =
                cacheFlake:
                mkIncrementalCcachePackage {
                  inherit
                    name
                    system
                    pkgs
                    drv
                    phase
                    nuke
                    ;
                  keepIncremental = inc.keepIncremental;
                  cache = if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake;
                };
            };
          });

      # NixOS/nix's flake splits `nix` into ~14 Meson/Ninja component
      # derivations (nix-util, nix-store, nix-expr, ...) sharing a scope
      # with overrideAllMesonComponents: an overlay applied to every
      # component, so building nix-cli applies it underneath too.
      #
      # withUnityBuild = false: unity builds merge many .cc files into
      # one translation unit, wrecking ccache's per-file hit rate.
      # withAWS = false on nix-store: aws-crt-cpp resolves via CMake,
      # whose compiler-detection breaks under a swapped ccacheStdenv.
      #
      # Only `target` gets a cache-varying restore script; every
      # dependency gets a fixed one. `cache` is a nested evaluation of
      # this same flake with its own `cache` input — if a shared
      # dependency's script varied with caching state, it would build a
      # different derivation (different `dev` output path) inside
      # `cache`'s tree vs. the target's tree, and dependents embed that
      # path in every -I/-isystem flag, turning every file into a miss
      # regardless of actual source changes. Tradeoff: only the
      # component you're building gets cross-build ccache hits; its
      # dependencies fall back to plain store substitution.
      mkIncrementalNixComponents =
        { system, target }:
        let
          pkgs = inputs.nix.inputs.nixpkgs.legacyPackages.${system};
          scope = (inputs.nix.lib.makeComponents {
            inherit pkgs;
            getStdenv = p: p.ccacheStdenv;
          }).overrideScope
            (finalScope: prevScope: {
              withUnityBuild = false;
              nix-store = prevScope.nix-store.override { withAWS = false; };
            });

          # random_seed: stdenv's cc-wrapper adds a fresh -frandom-seed
          # every invocation, a guaranteed miss otherwise.
          # include_file_mtime/ctime: every dependency header is
          # materialized fresh each build, which ccache's own "recently
          # modified" safety check would otherwise reject.
          ccacheTuning = ''
            export CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime
            export CCACHE_COMPRESS=1
            export CCACHE_UMASK=007
          '';
        in
        scope.overrideAllMesonComponents (
          finalAttrs: prevAttrs:
          if prevAttrs.pname == target then
            let
              inc = mkIncremental {
                name = prevAttrs.pname;
                inherit system;
                cacheVars = [ "CCACHE_DIR" ];
                nuke = false;
                keepIncremental = true;
              };
              env = ccacheEnv {
                inherit pkgs;
                pname = prevAttrs.pname;
                dir = inc.dir;
                debugDir = inc.debugDir;
              };
            in
            {
              outputs = (prevAttrs.outputs or [ "out" ]) ++ inc.outputs;
              # Meson resolves CMake deps (e.g. nix-expr's toml11) during
              # configurePhase, so CCACHE_DIR must be live before that.
              preConfigure = (prevAttrs.preConfigure or "") + inc.restore + env.setup;
              postInstall = (prevAttrs.postInstall or "") + env.report;
            }
          else
            {
              preConfigure =
                (prevAttrs.preConfigure or "")
                + ''
                  mkdir -p "$NIX_BUILD_TOP/ccache-scratch"
                  export CCACHE_DIR="$NIX_BUILD_TOP/ccache-scratch"
                ''
                + ccacheTuning;
            }
        );
    in
    {
      lib = {
        inherit
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
      };
      formatter = builtins.mapAttrs (system: pkgs: pkgs.nixfmt-tree) inputs.nixpkgs.legacyPackages;
      devShells = builtins.mapAttrs (system: pkgs: rec {
        default = pkgs.mkShell {
          name = "dev-shell";
          inputsFrom = builtins.attrValues inputs.self.packages.${system};
        };
      }) inputs.nixpkgs.legacyPackages;
      # Wraps `nix build --expr '(builtins.getFlake ...).<attrpath>.withCache "<cacheRef>"'`
      # so a third party can restore from a prior build without --impure or
      # editing their own flake.nix — `withCache` needs a rev-pinned ref, so
      # that inner eval stays pure. A bare `<flake-ref>#name` (no dots)
      # expands to `packages.<system>.name`, matching `nix build`'s own
      # shorthand; a dotted path (e.g. `checks.x86_64-linux.foo`) is used
      # as given.
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
              cargoLock = { lockFile = ./rust/Cargo.lock; };
              # Nix normalizes every unpacked source file's mtime to the
              # epoch, so Cargo's default mtime-based fingerprinting sees
              # "unchanged" on every rebuild and serves a stale binary.
              # checksum-freshness switches Cargo to content-hash-based
              # staleness detection (same fix ccache needed for the same
              # reason) — unstable, so needs RUSTC_BOOTSTRAP on stable.
              env.RUSTC_BOOTSTRAP = "1";
              cargoBuildFlags = [ "-Zchecksum-freshness" ];
            };
          };

          nix-incremental = (mkIncrementalNixComponents {
            inherit system;
            target = "nix-cli";
          }).nix-cli;
        }
        // lib.genAttrs nixComponentNames (
          target: (mkIncrementalNixComponents { inherit system target; }).${target}
        )
      ) inputs.nixpkgs.legacyPackages;
      # Self-tests: build a package cold, then call its own withCache
      # against that same cold build (synthesized as a `cache` attrset —
      # no git/flake fetch needed) and check the result. A regression here
      # previously slipped through as a real bug three times — nuke-refs
      # silently skipped whenever restoring from a real cache (caught by
      # nuke-refs-self-test, a minimal package whose build always writes
      # a fresh store-path reference into its cache dir, so a skipped
      # nuke leaks that reference into $incremental and Nix's own
      # reference scanner rejects the output), ccache's env vars
      # dropped by an outer overrideAttrs layer that withCache's default
      # implementation doesn't see (caught by c-self-test's hit-rate
      # assertion, which would silently read ~0% instead of ~100%), and
      # Cargo's mtime-based fingerprinting serving a stale binary from a
      # restored target/ dir (caught by rust-staleness-self-test).
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
          # Cargo's default fingerprinting is mtime-based, and Nix
          # normalizes every unpacked source file's mtime to the epoch —
          # so restoring a `target` dir from a build of *different*
          # source can serve a stale binary unless checksum-freshness
          # (or an equivalent) is on. This builds the same package from
          # two genuinely different sources through the same cache slot
          # and asserts the second binary reflects the second source.
          mkRustStalenessTest =
            { src, cache ? inputs.cache }:
            mkIncrementalRustPackage {
              name = "rust-staleness-self-test";
              inherit system pkgs cache;
              drv = pkgs.rustPlatform.buildRustPackage {
                name = "rust-staleness-self-test";
                inherit src;
                cargoLock = { lockFile = "${src}/Cargo.lock"; };
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
                packages.${system}."rust-staleness-self-test".incremental =
                  coldRustStalenessTest.incremental;
              };
            }).overrideAttrs
              (old: {
                postInstall =
                  old.postInstall
                  + ''
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
                postInstall =
                  old.postInstall
                  + ''
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
