{
  lib,
  system,
  pkgs,
  mkIncrementalCcacheAutotoolsPackage,
  mkIncrementalCcachePackage,
}:
# Bigger real-world C packages from nixpkgs, to check whether this
# caching approach is viable for speeding up iteration on something
# larger than this repo's own toy examples. Same pattern as
# hello-ccache.nix, just wrapping a real nixpkgs derivation instead of
# pkgs.hello.
#
# jq works well: ~2x wall-clock speedup restoring a warm cache
# (measured 51s -> 23s), 95% real ccache hit rate on a no-op rebuild.
# redis (ccacheOnly = true, below — no ./configure) does even better:
# 4m46s -> 42s, 96% real hits. tmux hits 100% but only gets ~1.6x
# (2m -> 1m13s): most of its wall-clock is autoconf's own
# `./configure` checks and a single-threaded final link, neither of
# which ccache touches — a real example of "100% cache hits" not
# implying "proportionally faster", not a bug. python3 (ccacheOnly,
# noDebug — see below) hits 99% but only gets ~1.2x (4m16s -> 3m24s):
# postInstall runs `python -m compileall` over the entire stdlib
# three times (plain/-O/-OO), pure Python bytecode compilation ccache
# never sees, on every build regardless of what changed.
#
# perl (ccacheOnly — Configure isn't autoconf, no --cache-file) hits
# 99% and gets ~1.6x (2m57s -> 1m48s): its -Dprefix=<placeholder>
# configureFlag looked like it might repeat openssh's $out-in-flags
# problem, but that flag only feeds Configure's own bookkeeping
# (Config.pm generation), never a C compile command line — confirmed
# by measured hit rate, not eval-time guesswork.
#
# llvm (ccacheOnly — CMake/Ninja, no ./configure at all) is the real
# "go bigger" test: 98% real ccache hits (4076/4159), buildPhase
# itself goes from 35m17s to 1m20s (~26x) restoring a same-source
# cache. Overall wall-clock only gets ~4.5x (10816s -> 2377s) because
# checkPhase runs LLVM's own lit-based test suite every build
# regardless of caching (432s-550s, ccache never touches it) — same
# "high hit rate doesn't mean proportional wall-clock" lesson as
# tmux, just at LLVM's scale. nuke-refs also has real work to do
# here: thousands of ccache debug-log files, more than python3's
# scale, and it still completed cleanly (no disallowed-reference
# failures) — the python3 debug-log leak seems to have been something
# specific to that build, not something proportional to file count.
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
# unusually large gnulib-based ./configure. gcc (pkgs.gcc.cc under
# ccacheStdenv) is the other side of that same blind spot: 0/0 ccache
# invocations on a warm rebuild, confirmed by grepping the build log
# for the ccache binary — GCC bootstraps its own compiler (`xgcc`)
# once using the host $CC, then uses that self-built xgcc (not the
# ccache-wrapped host compiler) for the ~2500 compiles of libgcc/
# libstdc++/libatomic/libsanitizer/etc. that make up the rest of the
# build. Structurally identical to emacs's libgccjit blind spot, just
# with GCC compiling itself instead of Lisp.
let
  # One example ends up in one of three shapes:
  # - autotools (jq, tmux): real ./configure, gets --cache-file too.
  # - ccacheOnly (redis, perl, llvm): no autoconf ./configure at all
  #   (redis: plain Makefile; perl: its own Configure, not autoconf —
  #   confirmed via empty nativeBuildInputs/no autoreconf-hook; llvm:
  #   CMake/Ninja), so --cache-file would be silently useless (or,
  #   for perl/llvm, not even understood).
  # - ccacheOnly + noDebug (python3): *does* have a real ./configure,
  #   but its nixpkgs derivation declares
  #   outputChecks.out.disallowedReferences on openssl-dev — a
  #   composed `incremental` output inherits the same check
  #   (confirmed: nix derivation eval shows outputChecks.incremental
  #   is identical to outputChecks.out) — and --with-openssl=<path>-dev
  #   is a literal configureFlag, so config.cache legitimately
  #   records that path in its cached check results, tripping the
  #   disallowed-reference check at build time ("output ... is not
  #   allowed to refer to ..."). Dropping --cache-file (ccacheOnly)
  #   avoids *that* conflict — but python3's scale (hundreds of
  #   autoconf conftest probes during configurePhase) surfaced a
  #   second, distinct one: ccacheEnv's CCACHE_DEBUG=1 writes every
  #   conftest compile's full command line (including -I<path>/include)
  #   verbatim to $incremental/debug-logs, and confirmed by direct
  #   grep for the exact disallowed store-path hash: those references
  #   survived a nuke-refs pass at this scale even though the
  #   identical mechanism worked on a synthetic reproduction of the
  #   same file content (root cause not fully isolated — plausibly a
  #   write/flush race between ccache's debug-log writers and the
  #   nuke-refs pass's directory listing). Disabling ccacheEnv's debug
  #   logging for this package (unset right after env.setup)
  #   sidesteps needing to scrub those files at all — confirmed fix,
  #   not a guess: 99% real hits, no disallowed-reference error,
  #   reproduced twice.
  mkNixpkgsExample =
    {
      name,
      drv,
      ccacheOnly ? false,
      noDebug ? false,
    }:
    let
      base =
        if ccacheOnly then
          mkIncrementalCcachePackage {
            inherit name system pkgs;
            phase = "postPatch"; # always runs, even with no configurePhase
            nuke = true; # see the big comment above for why
            drv = drv.override { stdenv = pkgs.ccacheStdenv; };
          }
        else
          mkIncrementalCcacheAutotoolsPackage {
            inherit name system pkgs;
            # Unlike hello-ccache, this build is big enough that
            # ccache's cache dir picks up real store-path references
            # (e.g. from debug info) — without nuke-refs recursing
            # into every level, that creates a same-derivation cycle
            # between the incremental and main outputs (confirmed:
            # dropping this reproduces "cycle detected ... in the
            # references of output 'bin' from output 'incremental'").
            # See lib/mk-incremental.nix's nukeScript.
            nuke = true;
            drv = drv.override { stdenv = pkgs.ccacheStdenv; };
          };
    in
    if noDebug then
      base.overrideAttrs (old: {
        postPatch = old.postPatch + "unset CCACHE_DEBUG CCACHE_DEBUGDIR\n";
      })
    else
      base;

  # Each entry's `-patched` sibling applies one small, real upstream
  # commit (patches/, one per package — see the commit each was
  # fetched from in that file's header) on top of the unpatched
  # package, sharing its cache key. Restoring from the unpatched
  # build's cache and building the patched one exercises a genuine
  # single-file source diff, not a no-op same-source rebuild — see
  # README.md.
  examples = [
    {
      name = "nixpkgs-jq";
      drv = pkgs.jq;
      patch = ../patches/jq-isspace-cast.patch;
    }
    {
      name = "nixpkgs-tmux";
      drv = pkgs.tmux;
      patch = ../patches/tmux-cmd-find-relative-targets.patch;
    }
    {
      name = "nixpkgs-redis";
      drv = pkgs.redis;
      ccacheOnly = true;
      patch = ../patches/redis-restore-ttl-overflow.patch;
    }
    {
      name = "nixpkgs-python3";
      drv = pkgs.python3;
      ccacheOnly = true;
      noDebug = true;
      patch = ../patches/python3-struct-pack-empty-pascal.patch;
    }
    {
      name = "nixpkgs-perl";
      drv = pkgs.perl;
      ccacheOnly = true;
      patch = ../patches/perl-regcomp-study-indent.patch;
    }
    {
      name = "nixpkgs-llvm";
      drv = pkgs.llvmPackages.llvm;
      ccacheOnly = true;
      patch = ../patches/llvm-memdep-reverse-map-helper.patch;
    }
  ];
in
lib.listToAttrs (
  lib.concatMap (
    {
      name,
      drv,
      patch,
      ...
    }@args:
    let
      mkArgs =
        drv:
        builtins.removeAttrs args [
          "patch"
          "drv"
        ]
        // {
          inherit name drv;
        };
    in
    [
      {
        inherit name;
        value = mkNixpkgsExample (mkArgs drv);
      }
      {
        name = "${name}-patched";
        value = mkNixpkgsExample (
          mkArgs (
            drv.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ patch ];
            })
          )
        );
      }
    ]
  ) examples
)
