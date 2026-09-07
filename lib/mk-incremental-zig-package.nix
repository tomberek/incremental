{ mkEcosystemPackage }:

# zig.hook's zigConfigurePhase only ever reassigns
# ZIG_GLOBAL_CACHE_DIR, never ZIG_LOCAL_CACHE_DIR — so both must be
# exported before configurePhase runs, i.e. in preConfigure.
mkEcosystemPackage {
  cacheVars = [
    "ZIG_LOCAL_CACHE_DIR"
    "ZIG_GLOBAL_CACHE_DIR"
  ];
  phase = "preConfigure";
}
