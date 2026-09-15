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
#
# nuke = false: a real, structural incompatibility between nuke-refs
# and cargo, not just "skip an optional pass". Unlike ccache's cache
# (text manifests/logs), cargo's target/ dir contains compiled
# build-script-build ELF binaries with a real store-path dynamic
# linker interpreter baked in — nuke-refs' text substitution corrupts
# that interpreter path, and cargo tries to re-execute the same cached
# binary on the next build ("could not execute process ... (never
# executed): No such file or directory", the classic broken-ELF-
# interpreter symptom). Confirmed directly: a cold build with the
# default nuke = true, then a same-source warm rebuild, failed there;
# rebuilding cold with nuke = false and repeating the warm rebuild
# didn't. The toy rust/ example never hit this — it has zero
# dependencies, so no crate compiles a build.rs at all.
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
    nuke = false;
    drv = withChecksumFreshness pkgs.nushell;
  };
  nixpkgs-nushell-patched = mkIncrementalRustPackage {
    name = "nixpkgs-nushell";
    inherit system pkgs;
    nuke = false;
    drv = withChecksumFreshness (
      pkgs.nushell.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/nushell-mkdir-verbose-existing-dir.patch ];
      })
    );
  };
}
