{
  system,
  pkgs,
  mkIncrementalRustPackage,
}:
mkIncrementalRustPackage {
  name = "rust";
  inherit system pkgs;
  drv = pkgs.rustPlatform.buildRustPackage {
    name = "rust";
    src = pkgs.lib.cleanSource ../rust;
    cargoLock = {
      lockFile = ../rust/Cargo.lock;
    };
    # Nix normalizes unpacked source mtimes to the epoch, so
    # Cargo's mtime-based fingerprinting sees "unchanged" every
    # rebuild and serves a stale binary. checksum-freshness
    # switches it to content-hash staleness (ccache's own fix,
    # same reason) — unstable, needs RUSTC_BOOTSTRAP on stable.
    env.RUSTC_BOOTSTRAP = "1";
    cargoBuildFlags = [ "-Zchecksum-freshness" ];
  };
}
