{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, cache, ... }:
    {
      packages = builtins.mapAttrs (system: pkgs: rec {
        golang = pkgs.buildGoModule {
          name = "golang";
          src = ./golang;
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
          src = ./zig;
          outputs = ["out" "incremental"];
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
