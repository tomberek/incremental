{ inputs, lib }:

# Restores a build's `incremental` output (from `cache`) and exports
# cacheVars pointing at it. `outputs` always includes "incremental" —
# a varying outputs list changes the derivation hash, breaking
# dependents' -I/-isystem-keyed caching. keepIncremental defaults off
# once already restoring from `cache`, to skip a redundant cache blob.
{
  name, # key into cache.packages.${system}
  system,
  cacheVars, # env vars to point at the restored cache dir
  cache ? inputs.cache, # an already-fetched flake to restore from
  nuke ? true, # nuke-refs a fresh (uncached) dir
  keepIncremental ? !(cache ? packages),
}:
let
  prevIncremental = cache.packages.${system}.${name}.incremental or "empty";
  isCached = cache ? packages;
  dir = if keepIncremental then "$incremental" else "$NIX_BUILD_TOP/incremental-scratch";
  debugDir = "$incremental/debug-logs"; # per-file hit/miss logs, always kept
in
{
  inherit
    isCached
    keepIncremental
    dir
    debugDir
    ;
  outputs = [ "incremental" ];
  restore =
    lib.optionalString (!keepIncremental) "mkdir -p $incremental\n"
    + ''
      mkdir -p empty
      cp -r ${prevIncremental} ${dir}
      chmod -R +w ${dir}
      mkdir -p ${debugDir}
    ''
    + lib.concatMapStrings (v: "export ${v}=${dir}\n") cacheVars;
  # Runs even when restoring from a real cache: the build still
  # writes new cache entries during this build on top of the
  # restored ones, and those were never nuked.
  #
  # find, not a fixed-depth glob: a cache tool's own manifest dir
  # (e.g. ccache's hex-keyed subdirs) can nest arbitrarily deep
  # depending on how big the build is — a shallow glob silently
  # leaves deeper refs un-nuked, which produced a real "cycle
  # detected ... in the references of output 'bin' from output
  # 'incremental'" on pkgs.jq. config.cache is excluded: unlike a
  # cache tool's own manifest, mkIncrementalAutotoolsPackage's
  # config.cache is autoconf's own check results and is *supposed* to
  # keep real store paths (e.g. the discovered path to `mkdir`) valid
  # across builds — nuking it corrupts those paths, and the next
  # ./configure re-run propagates the corruption straight into a
  # freshly generated Makefile (confirmed: "mkdir: No such file or
  # directory" pointing at a nuke-refs placeholder hash).
  nukeScript =
    if keepIncremental && nuke then
      "find ${dir} -type f -not -name config.cache -exec nuke-refs {} +\n"
    else
      "";
}
