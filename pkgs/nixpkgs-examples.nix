{
  inputs,
  system,
  pkgs,
  mkIncrementalAutotoolsPackage,
  mkIncrementalCcachePackage,
  ccacheEnv,
}:
# Bigger real-world C packages from nixpkgs, to check whether this
# caching approach is viable for speeding up iteration on something
# larger than this repo's own toy examples. Same pattern as
# hello-ccache.nix, just wrapping a real nixpkgs derivation instead of
# pkgs.hello.
#
# jq works well: ~2x wall-clock speedup restoring a warm cache
# (measured 51s -> 23s), 95% real ccache hit rate on a no-op rebuild.
# redis (mkIncrementalCcachePackage, below — no ./configure) does
# even better: 4m46s -> 42s, 96% real hits. tmux hits 100% but only
# gets ~1.6x (2m -> 1m13s): most of its wall-clock is autoconf's own
# `./configure` checks and a single-threaded final link, neither of
# which ccache touches — a real example of "100% cache hits" not
# implying "proportionally faster", not a bug. python3
# (mkIncrementalCcachePackage, not autotools — CCACHE_DEBUG disabled,
# see below) hits 99% but only gets ~1.2x (4m16s -> 3m24s):
# postInstall runs `python -m compileall` over the entire stdlib
# three times (plain/-O/-OO), pure Python bytecode compilation ccache
# never sees, on every build regardless of what changed.
#
# perl (mkIncrementalCcachePackage — Configure isn't autoconf, no
# --cache-file) hits 99% and gets ~1.6x (2m57s -> 1m48s): its
# -Dprefix=<placeholder> configureFlag looked like it might repeat
# openssh's $out-in-flags problem, but that flag only feeds
# Configure's own bookkeeping (Config.pm generation), never a C
# compile command line — confirmed by measured hit rate, not eval-time
# guesswork.
#
# Tried and dropped as examples: curl hits 100% in ccache but shows
# no real speedup — its build time is dominated by man-page
# rendering/install, not compilation, so ccache has nothing to save.
# openssh bakes its own $out into compile-time -D flags
# (-D_PATH_SSH_PROGRAM=..., similar for several other _PATH_* macros)
# — since $out is a different store path on every build with a
# different `cache` input, every single compile command differs
# between builds regardless of source changes, making ccache's key
# unique per-build and the hit rate genuinely 0%. nginx's `./configure`
# isn't autoconf-based and doesn't understand --cache-file at all
# (`error: invalid option "--cache-file=..."`), so it's incompatible
# with mkIncrementalAutotoolsPackage outright. emacs (--with-native-
# compilation) is the "go bigger" test that came back genuinely
# negative: ~16min either way (cold or warm), 1% real ccache hit rate
# (measured 3/155). Native-lisp .eln compilation runs through
# libgccjit in-process during Emacs's own "dump" step, never through
# $CC/ccache at all — a real, structural blind spot for a C-compiler-
# wrapping cache, not a bug here. The C sources that *are* visible to
# ccache also eat a lot of autoconf_test overhead from emacs's
# unusually large gnulib-based ./configure.
let
  # jq-style: autoconf-based, gets --cache-file too.
  mkNixpkgsExample =
    name: drv:
    let
      mkForCache =
        cache:
        let
          env = ccacheEnv {
            inherit pkgs;
            pname = name;
            dir = "$incremental";
            debugDir = "$incremental/debug-logs";
          };
        in
        (mkIncrementalAutotoolsPackage {
          inherit
            name
            system
            cache
            pkgs
            ;
          cacheVars = [ "CCACHE_DIR" ];
          # Unlike hello-ccache, this build is big enough that
          # ccache's cache dir picks up real store-path references
          # (e.g. from debug info) — without nuke-refs recursing into
          # every level, that creates a same-derivation cycle between
          # the incremental and main outputs (confirmed: dropping
          # this reproduces "cycle detected ... in the references of
          # output 'bin' from output 'incremental'"). See
          # lib/mk-incremental.nix's nukeScript.
          nuke = true;
          drv = drv.override { stdenv = pkgs.ccacheStdenv; };
          extraPostInstall = _isCached: env.report;
        }).overrideAttrs
          (old: {
            postPatch = old.postPatch + env.setup;
            passthru = old.passthru // {
              withCache =
                cacheFlake:
                mkForCache (if builtins.isString cacheFlake then builtins.getFlake cacheFlake else cacheFlake);
            };
          });
    in
    mkForCache inputs.cache;

  # redis-style: ccache-only via mkIncrementalCcachePackage instead of
  # mkIncrementalAutotoolsPackage. Different reasons a package ends up
  # here: redis and perl have no autoconf ./configure at all (redis: a
  # plain Makefile; perl: its own Configure script, not autoconf —
  # confirmed via an empty nativeBuildInputs/no autoreconf-hook), so
  # --cache-file would be silently useless (or, for perl, not even
  # understood). python3 *does* have a real ./configure, but its
  # nixpkgs derivation declares
  # outputChecks.out.disallowedReferences on openssl-dev — a
  # composed `incremental` output inherits the same check (confirmed:
  # nix derivation eval shows outputChecks.incremental is identical
  # to outputChecks.out) — and --with-openssl=<path>-dev is a literal
  # configureFlag, so config.cache legitimately records that path in
  # its cached check results, tripping the disallowed-reference check
  # at build time ("output ... is not allowed to refer to ...").
  # Dropping --cache-file (ccache-only) avoids *that* conflict — but
  # python3's scale (hundreds of autoconf conftest probes during
  # configurePhase) surfaced a second, distinct one: ccacheEnv's
  # CCACHE_DEBUG=1 writes every conftest compile's full command line
  # (including -I<path>/include) verbatim to $incremental/debug-logs,
  # and confirmed by direct grep for the exact disallowed store-path
  # hash: those references survived a nuke-refs pass at this scale
  # even though the identical mechanism worked on a synthetic
  # reproduction of the same file content (root cause not fully
  # isolated — plausibly a write/flush race between ccache's debug-log
  # writers and the nuke-refs pass's directory listing). Disabling
  # ccacheEnv's debug logging for this package (unset right after
  # env.setup) sidesteps needing to scrub those files at all —
  # confirmed fix, not a guess: 99% real hits, no disallowed-reference
  # error, reproduced twice.
  mkNixpkgsCcacheOnlyExample =
    name: drv:
    mkIncrementalCcachePackage {
      inherit name system pkgs;
      phase = "postPatch"; # always runs, even with no configurePhase
      nuke = true; # see mkNixpkgsExample above for why
      drv = drv.override { stdenv = pkgs.ccacheStdenv; };
    };

  mkNixpkgsCcacheOnlyNoDebugExample =
    name: drv:
    (mkNixpkgsCcacheOnlyExample name drv).overrideAttrs (old: {
      postPatch = old.postPatch + "unset CCACHE_DEBUG CCACHE_DEBUGDIR\n";
    });
in
{
  nixpkgs-jq = mkNixpkgsExample "nixpkgs-jq" pkgs.jq;
  nixpkgs-tmux = mkNixpkgsExample "nixpkgs-tmux" pkgs.tmux;
  nixpkgs-redis = mkNixpkgsCcacheOnlyExample "nixpkgs-redis" pkgs.redis;
  nixpkgs-python3 = mkNixpkgsCcacheOnlyNoDebugExample "nixpkgs-python3" pkgs.python3;
  nixpkgs-perl = mkNixpkgsCcacheOnlyExample "nixpkgs-perl" pkgs.perl;
  nixpkgs-llvm = mkNixpkgsCcacheOnlyExample "nixpkgs-llvm" pkgs.llvmPackages.llvm;
}
