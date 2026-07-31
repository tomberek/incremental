# Archive CA derivation.
#
# `inputs` is a native Nix list of { drv, name }. Same shape as linker.nix.
{
  compilerRoot,
  bashRoot,
  coreutilsRoot,
  outName,
  inputs,
  arFlags ? "cru",
  storeDepsJSON ? "[]",
  wrapperEnvJSON ? "{}",
}:
let
  pureStorePath = import ./pure-store-path.nix;
  bash        = pureStorePath bashRoot;
  coreutils   = pureStorePath coreutilsRoot;
  compiler    = pureStorePath compilerRoot;
  storeDeps   = map pureStorePath (builtins.fromJSON storeDepsJSON);
  wrapperEnv  = builtins.fromJSON wrapperEnvJSON;

  objArgs = builtins.concatStringsSep " " (map
    (i: "'${i.drv}/${i.name}'")
    inputs);
in
derivation ({
  name = "ar-${outName}";
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
      ar D${arFlags} "$out/${outName}" ${objArgs}
    ''
  ];

  _storeDeps = builtins.concatStringsSep ":" storeDeps;
} // wrapperEnv)
