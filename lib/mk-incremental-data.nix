{ inputs, lib }:

# Pure helper (no derivation attached) computing the shell snippets
# and paths every mkIncremental*Package wrapper needs: restores a
# build's `incremental` output (from `cache`) and exports cacheVars
# pointing at it. `outputs` always includes "incremental" — a varying
# outputs list changes the derivation hash, breaking dependents'
# -I/-isystem-keyed caching. keepIncremental defaults off once
# already restoring from `cache`, to skip a redundant cache blob.
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
      # Nix normalizes every file in a store output to the same fixed
      # epoch mtime during build finalization. Naive `cp -r` (no
      # --preserve=timestamps) stamps each file with the real wall-clock
      # time *at the moment cp copies it*, in whatever order it walks
      # the tree, not the actual build/dependency order — cargo's
      # cross-unit staleness check (independent of -Zchecksum-freshness,
      # which only covers per-file source rebuild-dirty checks) compares
      # a dependency's mtime against its dependent's and recompiles if
      # the dependency looks newer, so that copy-order noise alone
      # caused spurious recompiles. But `--preserve=timestamps` isn't
      # right either: it keeps every restored file at the frozen epoch
      # mtime, which is then *always older* than the vendor/source files
      # this same build already unpacked earlier (with a real "now"
      # timestamp) — cargo's build-script staleness check compares a
      # build script's tracked source against its own recorded output
      # sentinel, so an epoch-stamped sentinel always looks stale next
      # to a freshly-unpacked source. Confirmed both failure modes via
      # CARGO_LOG=cargo::core::compiler::fingerprint=trace on
      # nixpkgs-nushell. `find -exec touch {} +` isn't right either:
      # `+` batches arguments to stay under ARG_MAX, so a restored tree
      # large enough to need more than one touch invocation (confirmed:
      # nushell's does) gets more than one "now" — the same relative-
      # order noise as the original bug, just at finer grain. Capturing
      # one timestamp up front and passing it explicitly via `touch -t`
      # ties every batch, and therefore every restored file, to the
      # exact same instant regardless of how many touch invocations
      # `find` needs.
      cp -r ${prevIncremental} ${dir}
      chmod -R +w ${dir}
      now=$(date +%Y%m%d%H%M.%S)
      find ${dir} -exec touch -t "$now" {} +
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
  #
  # debugDir gets its own, *unconditional* nuke pass — not gated by
  # `nuke` like the manifest pass above. `nuke` exists to skip nuking
  # a cache tool's own manifest when the tool manages that directory
  # itself (mkIncrementalCcachePackage's default, "ccache manages its
  # own dir"); debugDir is different — this repo, not the tool,
  # controls its lifecycle (ccacheEnv always writes real compiler
  # command lines there whenever CCACHE_DEBUG is set, regardless of
  # `nuke`), so skipping it here was never justified by that
  # reasoning. It was also skipped entirely whenever keepIncremental
  # is false: `dir` (what the old code actually nuked) is a throwaway
  # scratch location outside any output in that case, but debugDir is
  # still $incremental/debug-logs — inside the *kept* output — so a
  # `find ${dir}` pass covered nothing there. This was a real,
  # deterministic bug (not the race it looked like): every warm
  # rebuild via `--override-input cache` sets keepIncremental=false,
  # so debug-logs was never nuked in that case at all. Confirmed
  # directly on nixpkgs-jq — restoring from a cold build's cache and
  # rebuilding left real, un-nuked store-path hashes (gcc, glibc,
  # ccache, the package's own store paths) in freshly-written
  # debug-logs files, with or without `nuke`. nixpkgs-python3's
  # disallowedReferences check is what turned this into a build
  # failure; every other ccache package (including nuke = false ones
  # like hello-ccache/c) has the identical leak, just without a check
  # strict enough to catch it.
  nukeScript =
    lib.optionalString keepIncremental (
      lib.optionalString nuke "find ${dir} -type f -not -name config.cache -exec nuke-refs {} +\n"
    )
    + "find ${debugDir} -type f -exec nuke-refs {} + 2>/dev/null || true\n";
}
