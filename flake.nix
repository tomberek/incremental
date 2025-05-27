{
  inputs.cache.url = "github:tomberek/empty";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs, cache, ... }:
    {
      packages = builtins.mapAttrs (system: pkgs: rec {
        thing = pkgs.buildGoModule {
          name = "thing";
          src = ./src;
          vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
          outputs = ["out" "incremental"];
          preBuild = ''
            mkdir empty
            cp -r ${cache.packages.${system}.thing.incremental or "empty"} $incremental
            chmod -R +w $incremental
            export GOCACHE=$incremental
          '';
          nativeBuildInputs = [ pkgs.nukeReferences ];
          postInstall = ''
            nuke-refs $incremental/*/*
          '';
        };
      }) nixpkgs.legacyPackages;
    };
}
