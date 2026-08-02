# Per-TU CA derivation.
#
# All toolchain paths are passed in as already-realised store paths, so
# this file does NOT depend on <nixpkgs> and does no fetching — that
# keeps parallel invocations from racing on nixpkgs input evaluation.
{
  # Toolchain roots — default to the pinned versions in toolchain.nix.
  # Callers can override individually if they need to (unusual).
  compilerRoot  ? (import ./toolchain.nix).compilerRoot,
  bashRoot      ? (import ./toolchain.nix).bashRoot,
  coreutilsRoot ? (import ./toolchain.nix).coreutilsRoot,
  toolBasename,            # "g++", "cc", "gcc", …
  srcTree,                 # /nix/store/…-src-…   (from `nix store add`)
  source,                  # relative path inside srcTree, e.g. "main.cc"
  outName,                 # object filename, e.g. "main.o"
  flagsJSON,               # JSON string, e.g. "[\"-O2\",\"-Wall\"]"
  storeDepsJSON ? "[]",    # JSON string list of extra /nix/store/... deps
                           # (e.g. protobuf/include roots) that the flags
                           # or wrapper env vars reference and must be
                           # present in the sandbox.
  wrapperEnvJSON ? "{}",   # JSON object of NIX_CFLAGS_COMPILE etc. that
                           # the Nix gcc-wrapper consults.
}:
let
  pureStorePath = import ./pure-store-path.nix;
  bash        = pureStorePath bashRoot;
  coreutils   = pureStorePath coreutilsRoot;
  compiler    = pureStorePath compilerRoot;
  src         = pureStorePath srcTree;
  flags       = builtins.fromJSON flagsJSON;
  quotedFlags = builtins.concatStringsSep " " (map (f: "'${f}'") flags);
  storeDeps   = map pureStorePath (builtins.fromJSON storeDepsJSON);
  wrapperEnv  = builtins.fromJSON wrapperEnvJSON;
in
derivation ({
  name = "tu-${outName}";
  system = builtins.currentSystem;

  __contentAddressed = true;
  outputHashMode = "nar";
  outputHashAlgo = "sha256";

  builder = "${bash}/bin/bash";
  args = [
    "-c"
    ''
      set -euo pipefail
      export PATH="${coreutils}/bin:${compiler}/bin"
      mkdir -p "$out"
      cd "$src"
      "${toolBasename}" ${quotedFlags} -c "$source" -o "$out/$outName"
    ''
  ];

  inherit src source outName;
  _storeDeps = builtins.concatStringsSep ":" storeDeps;
} // wrapperEnv)
