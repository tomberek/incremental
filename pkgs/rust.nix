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
    # cargoCheckHook reads cargoTestFlags, not cargoBuildFlags — it's
    # a separate `cargo test` invocation with its own fingerprint
    # database, and needs the flag too. Without it, `cargo test`
    # falls back to mtime-based staleness, wrongly concludes its own
    # (never-actually-built-this-run) test binary is already fresh,
    # and skips straight to running it — hence the intermittent
    # "could not execute process ... never executed": the file
    # genuinely doesn't exist, because cargo skipped building it.
    env.RUSTC_BOOTSTRAP = "1";
    cargoBuildFlags = [ "-Zchecksum-freshness" ];
    cargoTestFlags = [ "-Zchecksum-freshness" ];
  };
}
