{
  system,
  pkgs,
  mkIncrementalRustPackage,
}:
# The "go bigger" Rust test: nushell is a real, large multi-crate
# Cargo workspace (~50 crates under crates/), unlike this repo's own
# single-crate rust/ toy example — a much more realistic shape for
# whether -Zchecksum-freshness's fix (mtime-normalization defeating
# Cargo's own staleness check) holds up at scale. Its own patch
# (nushell-mkdir-verbose-existing-dir.patch) is a real, narrow
# single-file fix (crates/nu-command/src/filesystem/umkdir.rs) plus
# its own test file — the jq/kubeadm shape, not a widely-shared-header
# one, so restoring from the unpatched cache should only invalidate
# the one crate (nu-command) whose source actually changed plus
# whatever depends on it, not the whole workspace.
let
  # See rust/'s own package (pkgs/rust.nix) for why this is needed:
  # nixpkgs' nushell derivation doesn't set it itself, so without this
  # override cargo's mtime-based fingerprinting sees every restored
  # target/ dir as "unchanged" and serves a stale binary regardless of
  # source changes.
  #
  # doCheck is disabled: nushell's own integration suite includes a
  # couple of plugin-registry tests (plugin_stop_can_find_by_filename,
  # plugins::registry_file::plugin_add_and_then_use_by_filename) that
  # are flaky under this build's high --test-threads concurrency,
  # unrelated to anything caching touches — confirmed by a cold build
  # failing there with `doCheck` on. Same "test suite orthogonal to
  # the thing being measured" call as nixpkgs-protobuf's.
  withChecksumFreshness =
    drv:
    drv.overrideAttrs (old: {
      doCheck = false;
      env = (old.env or { }) // {
        RUSTC_BOOTSTRAP = "1";
      };
      cargoBuildFlags = (old.cargoBuildFlags or [ ]) ++ [ "-Zchecksum-freshness" ];
      cargoTestFlags = (old.cargoTestFlags or [ ]) ++ [ "-Zchecksum-freshness" ];
    });
in
{
  nixpkgs-nushell = mkIncrementalRustPackage {
    name = "nixpkgs-nushell";
    inherit system pkgs;
    drv = withChecksumFreshness pkgs.nushell;
  };
  nixpkgs-nushell-patched = mkIncrementalRustPackage {
    name = "nixpkgs-nushell";
    inherit system pkgs;
    drv = withChecksumFreshness (
      pkgs.nushell.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/nushell-mkdir-verbose-existing-dir.patch ];
      })
    );
  };
}
