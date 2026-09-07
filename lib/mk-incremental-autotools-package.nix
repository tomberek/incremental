{ inputs, mkIncrementalPackage }:

# Adds autoconf's --cache-file so AC_CHECK_*/AC_TRY_* results survive
# rebuilds. Never touches config.status/Makefile/config.h — those
# bake $out into text (or the compiled binary), unsafe to restore
# across a source patch. See README, "What's safe to cache".
{
  name,
  system,
  drv,
  pkgs,
  cache ? inputs.cache,
  cacheVars ? [ ],
  nuke ? cacheVars == [ ],
  extraPostInstall ? (_: ""),
}:
mkIncrementalPackage {
  inherit
    name
    system
    cache
    cacheVars
    nuke
    extraPostInstall
    pkgs
    ;
  keepIncremental = true; # --cache-file needs a real declared output
  phase = "postPatch";
  drv = drv.overrideAttrs (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [
      "--cache-file=${placeholder "incremental"}/config.cache"
    ];
  });
}
