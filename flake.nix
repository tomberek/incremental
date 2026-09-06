{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  inputs.nix.url = "github:NixOS/nix";

  outputs = inputs:
    let
      lib = inputs.nixpkgs.lib;

      # Restores the `incremental` output of a previous build (from
      # the `cache` flake input, usually overridden to an earlier
      # checkout) and points cacheVars at it. On a fresh cache,
      # nuke-refs it so store paths don't leak into the cache blob.
      #
      # By default, once we're already restoring from an injected
      # `cache` override, this build does NOT also produce its own
      # persisted "incremental" output — it uses a throwaway scratch
      # dir instead, still readable/writable for this build, just
      # discarded afterward. Otherwise every hop in a chain of
      # `--override-input cache ...` rebuilds would leave behind its
      # own redundant multi-hundred-MB cache blob, almost never read
      # again. Pass `keepIncremental = true` to opt back into
      # producing a real output (e.g. to keep chaining further).
      mkIncremental =
        {
          name, # key into inputs.cache.packages.${system}
          system,
          cacheVars, # env vars to point at the restored cache dir
          nuke ? true,
          keepIncremental ? !(inputs.cache ? packages),
        }:
        let
          prevIncremental = inputs.cache.packages.${system}.${name}.incremental or "empty";
          isCached = inputs.cache ? packages;
          dir = if keepIncremental then "$incremental" else "$NIX_BUILD_TOP/incremental-scratch";
        in
        {
          inherit isCached keepIncremental dir;
          outputs = lib.optional keepIncremental "incremental";
          restore =
            ''
              mkdir -p empty
              cp -r ${prevIncremental} ${dir}
              chmod -R +w ${dir}
            ''
            + lib.concatMapStrings (v: "export ${v}=${dir}\n") cacheVars;
          nukeScript = if keepIncremental && nuke && !isCached then "nuke-refs ${dir}/*/*\n" else "";
        };

      # Wraps a plain derivation with mkIncremental's outputs/restore/
      # nuke wiring. `phase` picks which builder phase to splice the
      # restore script into (postPatch, postConfigure, preConfigure).
      # `extraPostInstall` can see isCached for things like ccache's
      # --show-stats vs --zero-stats.
      mkIncrementalPackage =
        {
          name,
          system,
          cacheVars,
          drv,
          phase,
          nuke ? true,
          keepIncremental ? !(inputs.cache ? packages),
          extraPostInstall ? (_: ""),
        }:
        let
          inc = mkIncremental { inherit name system cacheVars nuke keepIncremental; };
        in
        drv.overrideAttrs (
          old:
          {
            outputs = (old.outputs or [ "out" ]) ++ inc.outputs;
            ${phase} = (old.${phase} or "") + inc.restore;
          }
          // lib.optionalAttrs (nuke || (extraPostInstall inc.isCached) != "") {
            postInstall = (old.postInstall or "") + inc.nukeScript + extraPostInstall inc.isCached;
          }
        );

      # mkIncrementalPackage plus autoconf's --cache-file, so
      # AC_CHECK_*/AC_TRY_* results survive rebuilds. Deliberately
      # doesn't touch config.status/Makefile/config.h — those bake
      # $out into text and (for gettext-style builds) into the
      # compiled binary, so they're not safe to restore across a
      # source-only patch. See README's "What's safe to cache".
      #
      # Always keeps the "incremental" output (keepIncremental = true,
      # unconditionally) — `--cache-file` below is wired via
      # `builtins.placeholder "incremental"`, a Nix-level
      # substitution that only resolves for a real, declared output;
      # unlike the plain env-var caches (ccache/Go/Zig), this
      # mechanism has no scratch-dir fallback to opt out into.
      mkIncrementalAutotoolsPackage =
        {
          name,
          system,
          drv,
          cacheVars ? [ ],
          nuke ? cacheVars == [ ],
          extraPostInstall ? (_: ""),
        }:
        mkIncrementalPackage {
          inherit name system cacheVars nuke extraPostInstall;
          keepIncremental = true;
          phase = "postPatch";
          drv = drv.overrideAttrs (old: {
            configureFlags = (old.configureFlags or [ ]) ++ [
              "--cache-file=${placeholder "incremental"}/config.cache"
            ];
          });
        };

      # NixOS/nix's flake splits the `nix` package into ~14 Meson/
      # Ninja component derivations (nix-util, nix-store, nix-expr,
      # ...) built via a shared scope (`nix.lib.makeComponents`) that
      # exposes `overrideAllMesonComponents`: an overlay-shaped
      # function applied to every component, transitively — building
      # nix-cli also applies it to nix-store/nix-util/etc. underneath.
      # That's the seam mkIncremental needs: one ccacheStdenv + one
      # restore script, applied once, reaching every component.
      #
      # Ninja (like make) is purely mtime-based with no content-hash
      # fallback, so restoring its own build-directory state hits the
      # same silent-stale-object problem ruled out for autoconf/make
      # (see README). ccache is the safe layer here, same as
      # hello-ccache — its correctness relies on hashing preprocessed
      # source + flags, not mtimes.
      #
      # `withUnityBuild` (on by default) merges many .cc files into
      # one translation unit per Meson's unity-build feature, which
      # coarsens ccache's per-file hit granularity; nix's own dev
      # shell already disables it for the same reason.
      #
      # `withAWS` on nix-store (on by default when aws-c-common is
      # available) pulls in aws-crt-cpp, resolved via CMake — under a
      # fully-swapped ccacheStdenv, CMake's own compiler-detection
      # probes for it fail. Not something this demo needs; disabled
      # here rather than chasing ccache+CMake compatibility.
      #
      # Uses NixOS/nix's own pinned nixpkgs (`inputs.nix.inputs.nixpkgs`),
      # not this flake's — the component `meson.build`s require a
      # newer Meson than this repo's nixpkgs pin ships.
      mkIncrementalNixComponents =
        { system }:
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
        in
        scope.overrideAllMesonComponents (
          finalAttrs: prevAttrs:
          let
            inc = mkIncremental {
              name = prevAttrs.pname;
              inherit system;
              cacheVars = [ "CCACHE_DIR" ];
              nuke = false; # ccache manages its own dir; nothing to scrub
            };
          in
          {
            outputs = (prevAttrs.outputs or [ "out" ]) ++ inc.outputs;
            # preConfigure, not postConfigure: Meson resolves
            # CMake-based deps (e.g. nix-expr's toml11) during
            # configurePhase itself, and needs CCACHE_DIR set before
            # that starts or CMake's compiler-detection silently
            # fails against the unwritable default ccache dir.
            #
            # CCACHE_SLOPPINESS=random_seed: stdenv's cc-wrapper adds
            # a fresh -frandom-seed=<random> to every invocation (for
            # reproducibility unrelated to ccache); without this,
            # every single compile is a guaranteed cache miss no
            # matter what — same fix hello-ccache already applies.
            preConfigure =
              (prevAttrs.preConfigure or "")
              + inc.restore
              + ''
                export CCACHE_SLOPPINESS=random_seed
                export CCACHE_COMPRESS=1
                export CCACHE_UMASK=007
                ${pkgs.ccache}/bin/ccache --dir "$CCACHE_DIR" --zero-stats > /dev/null
              '';
            postInstall =
              (prevAttrs.postInstall or "")
              + ''
                ${pkgs.ccache}/bin/ccache --dir "$CCACHE_DIR" --show-stats
                hits=$(${pkgs.ccache}/bin/ccache --dir "$CCACHE_DIR" --print-stats | awk '$1=="direct_cache_hit"||$1=="preprocessed_cache_hit"{s+=$2}END{print s+0}')
                misses=$(${pkgs.ccache}/bin/ccache --dir "$CCACHE_DIR" --print-stats | awk '$1=="cache_miss"{print $2+0}')
                total=$((hits + misses))
                pct=0
                if [ "$total" -gt 0 ]; then pct=$((hits * 100 / total)); fi
                echo "ccache[${prevAttrs.pname}]: $hits/$total hits ($pct%)"
              '';
          }
        );
    in
    {
      formatter = builtins.mapAttrs (system: pkgs: pkgs.nixfmt-tree) inputs.nixpkgs.legacyPackages;
      devShells = builtins.mapAttrs (system: pkgs: rec {
        default = pkgs.mkShell {
          name = "dev-shell";
          inputsFrom = builtins.attrValues inputs.self.packages.${system};
        };
      }) inputs.nixpkgs.legacyPackages;
      packages = builtins.mapAttrs (
        system: pkgs:
        let
          nixComponents = mkIncrementalNixComponents { inherit system; };
        in
        {
          hello-ccache =
            (mkIncrementalAutotoolsPackage {
              name = "hello-ccache";
              inherit system;
              cacheVars = [ "CCACHE_DIR" ];
              drv = (pkgs.hello.override { stdenv = pkgs.ccacheStdenv; }).overrideAttrs (old: {
                postPatch = ''
                  export CCACHE_COMPRESS=1
                  export CCACHE_UMASK=007
                  export CCACHE_SLOPPINESS="random_seed"
                  export CCACHE_NOINODECACHE=1
                '';
              });
              extraPostInstall =
                _isCached:
                ''
                  ${pkgs.ccache}/bin/ccache --dir "$incremental" --show-stats
                  hits=$(${pkgs.ccache}/bin/ccache --dir "$incremental" --print-stats | awk '$1=="direct_cache_hit"||$1=="preprocessed_cache_hit"{s+=$2}END{print s+0}')
                  misses=$(${pkgs.ccache}/bin/ccache --dir "$incremental" --print-stats | awk '$1=="cache_miss"{print $2+0}')
                  total=$((hits + misses))
                  pct=0
                  if [ "$total" -gt 0 ]; then pct=$((hits * 100 / total)); fi
                  echo "ccache[hello-ccache]: $hits/$total hits ($pct%)"
                '';
            }).overrideAttrs
              (old: {
                # inc.restore (which sets CCACHE_DIR) is appended
                # last inside mkIncrementalAutotoolsPackage's own
                # postPatch, so zeroing has to happen in one more
                # layer after it, to isolate this build's own hits
                # from history recorded in the restored cache.
                postPatch = old.postPatch + ''
                  ${pkgs.ccache}/bin/ccache --dir "$incremental" --zero-stats > /dev/null
                '';
              });

          golang = mkIncrementalPackage {
            name = "golang";
            inherit system;
            cacheVars = [ "GOCACHE" ];
            phase = "postConfigure";
            drv = pkgs.buildGoModule {
              name = "golang";
              src = pkgs.lib.cleanSource ./golang;
              vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
              nativeBuildInputs = [ pkgs.nukeReferences ];
            };
          };

          zig = mkIncrementalPackage {
            name = "zig";
            inherit system;
            cacheVars = [
              "ZIG_LOCAL_CACHE_DIR"
              "ZIG_GLOBAL_CACHE_DIR"
            ];
            phase = "preConfigure";
            drv = pkgs.stdenvNoCC.mkDerivation {
              name = "zig";
              src = pkgs.lib.cleanSource ./zig;
              nativeBuildInputs = [
                pkgs.zig.hook
                pkgs.nukeReferences
              ];
            };
          };

          nix-incremental = nixComponents.nix-cli;
        }
        # Each component on nix-cli's dependency chain also needs its
        # own top-level package attribute, named after its `pname` —
        # mkIncrementalNixComponents looks up
        # `inputs.cache.packages.${system}.${pname}.incremental` to
        # restore that component's ccache dir, so the name has to
        # resolve at the top level of *this* flake's own `packages`,
        # the same way hello-ccache/golang/zig do.
        // lib.genAttrs [
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
        ] (pname: nixComponents.${pname})
      ) inputs.nixpkgs.legacyPackages;
    };
}
