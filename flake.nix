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
      mkIncremental =
        {
          name, # key into inputs.cache.packages.${system}
          system,
          cacheVars, # env vars to point at the restored $incremental
          nuke ? true,
        }:
        let
          prevIncremental = inputs.cache.packages.${system}.${name}.incremental or "empty";
          isCached = inputs.cache ? packages;
        in
        {
          inherit isCached;
          outputs = [ "incremental" ];
          restore =
            ''
              mkdir -p empty
              cp -r ${prevIncremental} $incremental
              chmod -R +w $incremental
            ''
            + lib.concatMapStrings (v: "export ${v}=$incremental\n") cacheVars;
          nukeScript = if nuke && !isCached then "nuke-refs $incremental/*/*\n" else "";
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
          extraPostInstall ? (_: ""),
        }:
        let
          inc = mkIncremental { inherit name system cacheVars nuke; };
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
              '';
            postInstall =
              (prevAttrs.postInstall or "")
              + (
                if inc.isCached then
                  ''
                    ${pkgs.ccache}/bin/ccache --dir "$incremental" --show-stats
                  ''
                else
                  ''
                    ${pkgs.ccache}/bin/ccache --dir "$incremental" --zero-stats --show-stats
                  ''
              );
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
          hello-ccache = mkIncrementalAutotoolsPackage {
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
              isCached:
              if isCached then
                ''
                  ${pkgs.ccache}/bin/ccache --dir "$incremental" --show-stats
                ''
              else
                ''
                  ${pkgs.ccache}/bin/ccache --dir "$incremental" --zero-stats --show-stats
                '';
          };

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
