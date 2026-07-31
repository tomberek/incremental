# Link CA derivation.
#
# `inputs` is a native Nix list of { drv, name }. Each `drv` is either
# a derivation (thunk mode: not-yet-built, produced by `import
# .../foo.nix`) or a `pureStorePath` result (realise mode: already in
# the store). Either way, `${item.drv}/${item.name}` interpolates to
# the linker CLI.
{
  compilerRoot,
  toolBasename,
  bashRoot,
  coreutilsRoot,
  outName,
  inputs,
  flagsJSON,
  storeDepsJSON ? "[]",
  wrapperEnvJSON ? "{}",
}:
let
  pureStorePath = import ./pure-store-path.nix;
  bash        = pureStorePath bashRoot;
  coreutils   = pureStorePath coreutilsRoot;
  compiler    = pureStorePath compilerRoot;
  flags       = builtins.fromJSON flagsJSON;
  quotedFlags = builtins.concatStringsSep " " (map (f: "'${f}'") flags);
  storeDeps   = map pureStorePath (builtins.fromJSON storeDepsJSON);
  wrapperEnv  = builtins.fromJSON wrapperEnvJSON;

  objArgs = builtins.concatStringsSep " " (map
    (i: "'${i.drv}/${i.name}'")
    inputs);
in
derivation ({
  name = "bin-${outName}";
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
      "${toolBasename}" ${quotedFlags} ${objArgs} -o "$out/${outName}"
    ''
  ];

  _storeDeps = builtins.concatStringsSep ":" storeDeps;
} // wrapperEnv)
