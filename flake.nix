{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, cache, ... }:
    {
      devShells = builtins.mapAttrs (system: pkgs: rec {
          default = pkgs.mkShell {
            name = "dev-shell";
            inputsFrom = builtins.attrValues self.packages.${system};
        };
      }) nixpkgs.legacyPackages;
      packages = builtins.mapAttrs (system: pkgs: rec {
        hello-ccache = (pkgs.hello.override {stdenv = pkgs.ccacheStdenv;}).overrideAttrs (old: {
          outputs = (old.outputs or ["out"]) ++ [ "incremental" ];
          configureFlags = (old.configureFlags or []) ++ [
	    "--cache-file=${placeholder "incremental"}/config.cache"
	  ];
          postPatch = ''
            export CCACHE_COMPRESS=1
            export CCACHE_DIR="$incremental"
            export CCACHE_UMASK=007
            export CCACHE_SLOPPINESS="random_seed"
            export CCACHE_NOINODECACHE=1

            mkdir empty
            cp -r ${cache.packages.${system}.hello-ccache.incremental or "empty"} $incremental
            chmod -R +w $incremental
          '';
          postInstall = (old.postInstall or "") + (if cache?packages then ''
            ${pkgs.ccache}/bin/ccache --dir "$incremental" --show-stats
          '' else ''
            ${pkgs.ccache}/bin/ccache --dir "$incremental" --zero-stats --show-stats
          '');
        });

        golang = pkgs.buildGoModule {
          name = "golang";
          src = pkgs.lib.cleanSource ./golang;
          vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
          outputs = ["out" "incremental"];
          postConfigure = ''
            mkdir empty
            cp -r ${cache.packages.${system}.golang.incremental or "empty"} $incremental
            chmod -R +w $incremental
            export GOCACHE=$incremental
          '';
          nativeBuildInputs = [ pkgs.nukeReferences ];
          postInstall = if cache?packages then "" else ''
            nuke-refs $incremental/*/*
          '';
        };

        zig = pkgs.stdenvNoCC.mkDerivation {
          name = "zig";
          outputs = ["out" "incremental"];
          src = pkgs.lib.cleanSource ./zig;
          nativeBuildInputs = [
            pkgs.zig.hook
            pkgs.nukeReferences
          ];
          preConfigure = ''
            mkdir empty
            cp -r ${cache.packages.${system}.zig.incremental or "empty"} $incremental
            chmod -R +w $incremental
            export ZIG_LOCAL_CACHE_DIR=$incremental
            export ZIG_GLOBAL_CACHE_DIR=$incremental
          '';
          postInstall = if cache?packages then "" else ''
            nuke-refs $incremental/*/*
          '';
        };
      }) nixpkgs.legacyPackages;
    };
}
