{ mkEcosystemPackage }:

# Unlike Go/Zig, `swift build` has no env var for its scratch (build
# artifacts) directory — only a --scratch-path CLI flag. So the
# exported var here isn't read by the toolchain itself; it's read by
# the package's own buildPhase/installPhase (see pkgs/swift.nix),
# which pass it through as --scratch-path. preConfigure just needs to
# run before that buildPhase.
mkEcosystemPackage {
  cacheVars = [ "SWIFTPM_SCRATCH_PATH" ];
  phase = "preConfigure";
}
