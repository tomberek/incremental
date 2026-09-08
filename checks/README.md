# Checks

`nix flake check` builds three self-tests that catch regressions in
the caching mechanism itself, not in any particular package:

- `c-self-test` builds `c` cold, then calls its own `withCache` against
  that same build and asserts the ccache hit rate stays near 100% —
  this is what caught a real bug where an outer `overrideAttrs` layer
  (ccache's env setup) wasn't carried into the inherited `withCache`,
  silently dropping the hit rate to 0%.
- `nuke-refs-self-test` does the same restore cycle for a minimal
  package whose build always references `pkgs.hello` and sets
  `disallowedReferences = [ pkgs.hello ]` — this is what caught a real
  bug where `nuke-refs` was skipped whenever restoring from a real
  cache, letting a fresh reference leak into the persisted output.
- `rust-staleness-self-test` builds a minimal Rust binary with source
  "cold", then restores that build's cache while building from
  different source that prints "warm", and asserts the binary
  actually prints "warm" — this is what caught a real bug where
  Cargo's mtime-based fingerprinting served a stale binary from a
  restored `target/` dir regardless of what source changed, before
  `mkIncrementalRustPackage` added `-Zchecksum-freshness`.

All three synthesize a `cache` attrset directly from a cold build's
own `.incremental` output (`withCache` accepts either a rev-pinned
flake ref or an already-fetched flake), so none of them needs
git/network access, and all stay hermetic under the build sandbox.

`scripts/verify-override-input.sh` checks a different layer: the
literal `--override-input cache "git+file://$PWD?ref=HEAD"` CLI
workflow documented in the main README, for real, for every example.
For each of `c`/`golang`/`zig`/`rust` it builds cold, edits the source
with a unique marker, rebuilds via `--override-input`, and asserts the
marker actually shows up when running the binary (reverting the edit
either way). `hello-ccache` has no source to edit, so it instead
deletes its existing output and forces a fully local rebuild (its
derivation is otherwise byte-identical run to run, so Nix — or a
configured remote builder — would just hand back the old output) and
asserts a nonzero ccache hit count. CI runs both this and
`nix flake check` on every push.

The `nix-*` component packages and `nix-incremental` (full NixOS/nix
builds) are excluded from that on-push CI — too expensive to run on
every commit. `nix-components.yml` builds them instead on manual
`workflow_dispatch`, for periodic/on-demand coverage.
