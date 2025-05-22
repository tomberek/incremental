{
  inputs.cache.url = "github:nix-community/nixpkgs-lib";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs, cache, ... }:
    {
      packages = builtins.mapAttrs (system: pkgs: rec {
        thing = pkgs.buildGoModule {
          name = "thing";
          src = ./src;
          vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
          env.GODEBUG="gocachehash=1";
          outputs = ["out" "intermediates"];
          preBuild = ''
            mkdir empty
            cp -r ${cache.packages.${system}.thing.intermediates or "empty"} $intermediates
            chmod -R +w $intermediates
            export GOCACHE=$intermediates
          '';
          nativeBuildInputs = [ pkgs.nukeReferences ];
          postInstall = ''
            nuke-refs $intermediates/*/*
          '';
        };
        default = cache:
         let
          download = pkgs.runCommandCC "download" {
              src = ./src;
              buildInputs = [ pkgs.go pkgs.netcat ];
              unsafeDiscardReferences.out = true;
              outputs = [ "out" ];
              __structuredAttrs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = "sha256-vSroalX+Ci3AofII6v6XmgyLrBdSZ2+GMtbYAxLorwI=";
           } ''
              . "$NIX_ATTRS_SH_FILE"
              mkdir -p $out
              export HOME=$PWD

              export CGO_ENABLED=1
              export GOFLAGS=-trimpath
              export GODEBUG="gocachehash=1"
              cp --archive $src src
              chmod +w src
              cd src
              go build -x -o ex

              mv -t $out $HOME/.*
          '';
         in
          pkgs.runCommandCC "thing"
            {
              src = ./src;
              __impure = true;
              buildInputs = [ pkgs.go pkgs.netcat pkgs.findutils];
              outputs = ["out" "intermediates"];
              passthru.download = download;
            }
            ''
              mkdir -p $out/bin
              mkdir $intermediates
              export HOME=$PWD
              cp --archive ${download}/.cache .
              cp --archive ${download}/.config .
              chmod -R +w .cache

              export CGO_ENABLED=1
              export GOFLAGS=-trimpath
              export GODEBUG="gocachehash=1"
              cp --archive $src src
              chmod +w src
              cd src
              go build -x -o ex
            '';
      }) nixpkgs.legacyPackages;
    };
}
