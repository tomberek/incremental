{
  inputs.garnix.url = "github:garnix-io/incrementalize";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  outputs =
    { self, nixpkgs, garnix, ... }:
    garnix.lib.withCaches  {
      packages = builtins.mapAttrs (system: pkgs: rec {
        thing = derivation {
          name = "thing";
          inherit system;
          builder = "/bin/sh";
          outputs = ["out" "intermediates"];
          __contentAddressed = true;
          args = ["-c" ''
            echo a b
            echo a > $out
            echo b > $intermediates
          ''];
        };
        last = derivation {
          name = "last";
          inherit system;
          builder = "/bin/sh";
          outputs = ["out" ];
          args = ["-c" ''
            echo ${thing} > $out
          ''];
        };
        default = cache:
         let
          download = pkgs.runCommandCC "download" {
              src = self;
              buildInputs = [ pkgs.go pkgs.netcat ];
              unsafeDiscardReferences.out = true;
              outputs = [ "out" ];
              __structuredAttrs = true;
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = "";
           } ''
              . "$NIX_ATTRS_SH_FILE"
              mkdir -p $out
              export HOME=$out

              export CGO_ENABLED=1
              cd $src
              go build -x -o /dev/null
          '';
         in
          pkgs.runCommandCC "thing"
            {
              src = ./.;
              buildInputs = [ pkgs.go pkgs.netcat ];
              outputs = ["out" "intermediates"];
              __impure = true;
              passthru.download = download;
            }
            ''
              mkdir -p $out/bin
              echo ${download}

              mkdir $intermediates
              export HOME=$intermediates
	      cd $HOME
              cp -r ${download}/* || true
              chmod -R u+w .cache || true
              ls -alh

              export CGO_ENABLED=1
              cd $src
              #export GODEBUG=gocachehash=1 
              go build -o $out/bin/ex 2>&1 | head -n 100
            '';
      }) nixpkgs.legacyPackages;
    };
}
