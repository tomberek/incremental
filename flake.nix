{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

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
        rec {
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
        }
      ) inputs.nixpkgs.legacyPackages;
    };
}
