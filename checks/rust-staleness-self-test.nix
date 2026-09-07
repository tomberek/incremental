{
  inputs,
  system,
  pkgs,
  mkIncrementalRustPackage,
}:
let
  # Builds the same package from two different sources through the
  # same cache slot and asserts the second binary reflects the
  # second source — see the `rust` package in ../pkgs for why this
  # can go wrong without checksum-freshness.
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
      cp ${../rust/Cargo.lock} $out/Cargo.lock
      cp ${../rust/Cargo.toml} $out/Cargo.toml
      echo 'fn main() { println!("${text}"); }' > $out/src/main.rs
    '';
  coldRustStalenessTest = mkRustStalenessTest { src = rustSrc "cold"; };
in
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
  })
