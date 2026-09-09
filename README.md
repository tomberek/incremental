# Incremental builds

Reuse outputs/caches from a previous build by overriding the `cache`
flake input to an earlier checkout (or a previous build, or whatever
ref you want).

## Using this as a library from another flake

`inputs.cache`/`--override-input` requires the flake being built to declare
`cache` as an input — fine for packages that live in this repo, but it means
a third party has to edit their own `flake.nix` to opt in.

Every `mkIncrementalPackage`-based derivation also carries
`passthru.withCache`, a plain function that takes a rev-pinned flake ref and
returns the same package restoring from that build instead — no
`--override-input`, no changes to the caller's `flake.nix`:

```nix
# their flake.nix — no inputs.cache, no other changes needed
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.incremental.url = "github:tomberek/incremental";
  outputs = { self, nixpkgs, incremental, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.default = incremental.lib.mkIncrementalGoPackage {
        name = "myapp";
        system = "x86_64-linux";
        inherit pkgs; # supplies nuke-refs
        drv = pkgs.buildGoModule {
          pname = "myapp";
          src = ./.;
          vendorHash = "...";
        };
      };
    };
}
```

```
$ nix build .#default   # also produces .#default.incremental
echo "// x" >> main.go
$ nix run github:tomberek/incremental#with-cache -- .
```

`with-cache` takes the baseline first, then the target being built —
"use this baseline, build this". Target defaults to `.#default`,
matching `nix build`'s own default; give it explicitly for anything
else:

```
$ nix run github:tomberek/incremental#with-cache -- . ".#default"
```

Baseline is auto-pinned to its locked rev via `nix flake metadata` if
it isn't already, so a plain local path or branch name works too, not
just an explicit `?rev=<sha>`:

```
$ nix run github:tomberek/incremental#with-cache -- \
    "git+file://$PWD?rev=<pre-edit-commit>" ".#default"
```

The target, by contrast, is built with `--impure` and can stay
unlocked/dirty — it's the thing actually being built, not looked up
inside `builtins.getFlake` for its own inputs. A bare name after `#`
(like `default` above) expands to `packages.<current-system>.default`,
matching `nix build`'s own shorthand; use a full dotted path (e.g.
`checks.x86_64-linux.foo`) for anything else.

The `with-cache` app is just this, spelled without `--impure --expr`:

```
nix build --impure --expr \
  'let pkg = builtins.foldl'"'"' (acc: a: acc.${a})
       (builtins.getFlake "<target-flake-ref>") ["packages" "x86_64-linux" "default"];
   in pkg.withCache "<baseline-locked-flake-ref>"'
```

Every `mkIncrementalPackage`-based derivation also carries
`passthru.asCacheApp`: the same `withCache` call again, but with the
baseline pre-filled to *this build's own already-fetched source*
(`inputs.self`, pinned via its own content hash — works even from a
dirty tree, no commit required). Useful when the baseline is a flake
you're already inside, so there's no flake ref to type out at all:

```
nix run <this-flake>#default.passthru.asCacheApp -- <target-flake-ref>#<name-or-attrpath>
```

Note this has to be a plain derivation, not a `type = "app"` value —
`nix run` only recognizes that shape under `apps.<system>.<name>`, not
at an arbitrary attribute path. `writeShellApplication` (what builds
it) sets `meta.mainProgram`, which is enough for `nix run` to find the
right binary regardless.

`mkIncrementalGoPackage`, `mkIncrementalZigPackage`, and
`mkIncrementalRustPackage` bake in the right `cacheVars`/`phase` for
those ecosystems (see "Examples in this repo" below for why each
needs what it needs). For anything else — autoconf's `--cache-file`,
a second cache tool doesn't have a wrapper for — compose
`mkIncrementalPackage`/`mkIncrementalAutotoolsPackage` directly.

## Examples in this repo

### Go

Uses `mkIncrementalGoPackage`: `buildGoModule`'s own `configurePhase`
sets `$GOCACHE` and only then runs `postConfigure`, so that's the
hook `GOCACHE` gets pointed at the restored cache from.

```
$ nix build .#golang
echo "// hi" >> golang/main.go
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#golang
```

### Zig

Uses `mkIncrementalZigPackage`: `zig.hook`'s `zigConfigurePhase`
reassigns `ZIG_GLOBAL_CACHE_DIR` but never `ZIG_LOCAL_CACHE_DIR`, so
both vars are exported earlier, in `preConfigure`.

```
$ nix build .#zig
echo "// hi" >> zig/main.zig
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#zig
```

### Rust

Uses `mkIncrementalRustPackage`, which restores Cargo's own build
cache (`CARGO_TARGET_DIR`) — but pointing that at a restored dir isn't
enough on its own. `buildRustPackage`'s `cargoInstallHook` looks for a
fixed *relative* path (`target/<subdir>/<buildType>`), not
`$CARGO_TARGET_DIR`, so the wrapper symlinks `./target` to the
restored dir in `preBuild` instead of exporting an env var.

More importantly: Cargo's default fingerprinting is mtime-based, and
Nix normalizes every unpacked source file's mtime to the epoch, so a
restored `target/` looks "fresh" to Cargo regardless of what actually
changed — the same failure mode this repo already avoids for
Autotools by not caching `config.status`. The fix here is Cargo's
`-Zchecksum-freshness` (unstable, unlocked on stable via
`RUSTC_BOOTSTRAP=1`), which switches Cargo to content-hash-based
staleness detection, the same fix ccache needed for the same reason.
`mkIncrementalRustPackage`'s example sets both; a `buildRustPackage`
without them would silently serve stale binaries when restoring from
a cache built from different source — the `rust-staleness-self-test`
check catches exactly this.

```
$ nix build .#rust
echo '// hi' >> rust/src/main.rs
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#rust
```

### ccache (hello-ccache)

```
$ nix build .#hello-ccache
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#hello-ccache
```

`hello-ccache` also caches autoconf's check results via
`--cache-file`: `nix build -L` shows `configure: loading cache
.../config.cache`, plus a ccache hit rate on rebuild.

### Real nixpkgs packages (nixpkgs-jq, nixpkgs-redis, nixpkgs-tmux)

The above are toy examples; these check whether this is viable on
something real. `nixpkgs-jq` wraps `pkgs.jq` (same
`mkIncrementalAutotoolsPackage` pattern, `pkgs.jq.override { stdenv =
pkgs.ccacheStdenv; }`) — measured 38s cold → 22s restoring a
same-source cache, 95% real ccache hit rate. `nixpkgs-redis` wraps
`pkgs.redis`, which has no `./configure` at all (plain Makefile), so
it's built with `mkIncrementalCcachePackage` directly instead
(ccache-only, no `--cache-file` claim) — measured 4m46s cold → 42s,
96% real ccache hit rate. `nixpkgs-tmux` wraps `pkgs.tmux` — 100%
real ccache hit rate, but only ~1.6x wall-clock (2m → 1m13s): most of
tmux's build time is autoconf's own `./configure` checks plus a
single-threaded final link, neither of which ccache touches. A useful
reminder that "100% cache hits" doesn't automatically mean
"proportionally faster" — it depends on how much of the wall-clock is
actually compilation.

```
$ nix build .#nixpkgs-jq
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-jq
$ nix build .#nixpkgs-redis
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-redis
$ nix build .#nixpkgs-tmux
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-tmux
```

Not every C package benefits the same way — tried and dropped as
examples for instructive reasons:

- `curl` hits 100% in ccache but shows no real wall-clock speedup —
  its build time is dominated by man-page rendering/install steps,
  not compilation, so there's nothing for ccache to save.
- `openssh` bakes its own `$out` into compile-time `-D` flags
  (`-D_PATH_SSH_PROGRAM=...` and similar `_PATH_*` macros). Since
  `$out` is a different store path on every build with a different
  `cache` input, every compile command differs between builds
  regardless of source changes — ccache's key ends up unique per
  build, and the real hit rate is 0%.
- `nginx`'s `./configure` isn't autoconf-based and doesn't recognize
  `--cache-file` at all (`error: invalid option
  "--cache-file=..."`), so it's incompatible with
  `mkIncrementalAutotoolsPackage` outright.
- `emacs` (`--with-native-compilation`) was the "go bigger" test —
  ~16 minutes either way, cold or warm, 1% real ccache hit rate
  (measured 3/155). Native-lisp `.eln` compilation runs through
  `libgccjit` in-process during Emacs's own "dump" step, never
  through `$CC`/ccache — a real, structural blind spot for a
  C-compiler-wrapping cache, not a bug here. The C sources that *are*
  visible to ccache also spend a lot of time on `autoconf_test`
  overhead from emacs's unusually large gnulib-based `./configure`.

### Adding a new ccache-cached package

`mkIncrementalCcachePackage` is the one-call-site way to add ccache
caching to a C/C++ package. `c/` is a minimal worked example:

```nix
c = mkIncrementalCcachePackage {
  name = "c";
  inherit system pkgs;
  phase = "postPatch"; # whichever phase runs before your compiler does
  drv = pkgs.ccacheStdenv.mkDerivation {
    name = "c";
    src = pkgs.lib.cleanSource ./c;
    buildPhase = "$CC -c a.c -o a.o && ...";
    installPhase = "mkdir -p $out/bin && cp c $out/bin/";
  };
};
```

```
$ nix build .#c
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#c
```

- `drv` must already be built with `ccacheStdenv` —
  `pkgs.ccacheStdenv.mkDerivation { ... }`, or `.override { stdenv =
  pkgs.ccacheStdenv; }` on an existing `callPackage`-based one.
  Swapping `stdenv` after construction doesn't work on a plain
  `stdenv.mkDerivation` result — it has no `.override`. An eval-time
  assert catches this.
- `phase` must be a hook that still runs given whatever the package
  skips — e.g. `preConfigure` lives inside `configurePhase`, so
  `dontConfigure = true` skips both. `postPatch` always runs.

### NixOS/nix itself (nix-incremental)

`github:NixOS/nix`'s flake splits `nix` into ~14 Meson/Ninja component
derivations (`nix-util`, `nix-store`, `nix-expr`, ...) sharing a scope
with `overrideAllMesonComponents`, an overlay applied to every
component transitively — building `nix-cli` applies it to everything
underneath too.

```
$ nix build .#nix-fetchers
# edit a .cc file, e.g. under a local NixOS/nix checkout
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nix-fetchers
```

Each component (`nix-util`, `nix-store`, `nix-fetchers`, `nix-expr`,
`nix-flake`, `nix-main`, `nix-cmd`, and their `-c` variants) is its own
package; `nix-incremental` builds the full CLI.

**Want every component to individually benefit from caching, not just
whichever one you name?** Build `nix-all-components` instead of
`nix-incremental` — it's every component built as its own top-level
target (via `symlinkJoin`), so each keeps its own cache-varying
restore script and reports its own hit rate, instead of `nix-cli`
pulling them in as fixed-script dependencies:

```
$ nix build .#nix-all-components
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nix-all-components
```

**Only the component you're building gets a cache-varying restore
script — every dependency gets a fixed one.** `cache` is a full nested
evaluation of this same flake with its own `cache` input. If a shared
dependency like `nix-store` had a script whose text varied with
caching state, it would compile to a different derivation (different
`dev` output path) inside `cache`'s tree vs. the target's tree —
dependents embed that path in every `-I`/`-isystem` flag, so their
ccache manifest key would then differ between builds and every file
would report a miss regardless of actual source changes. Tradeoff:
only the actively-built component gets cross-build ccache hits; its
dependencies fall back to Nix's own store substitution.

The ccache summary prints the top miss reasons from the debug log
under `$incremental/debug-logs`:

```
ccache[nix-fetchers]: 18/18 hits (100%)
```

or, on a miss:

```
ccache[nix-fetchers]: 0/18 hits (0%)
ccache[nix-fetchers]: miss reasons (top):
ccache[nix-fetchers]:   18 cache_miss
```

**`--override-input nix <path>` needs `cache/nix` overridden too.**
`cache` resolves its own `nix` input from `flake.lock` independently —
overriding the top-level `nix` alone doesn't affect `cache`'s copy:

```
nix build .#nix-fetchers \
  --override-input nix ~/my-nix-checkout \
  --override-input cache "git+file://$PWD?ref=HEAD" \
  --override-input cache/nix ~/my-nix-checkout \
  -L
```

`scripts/build-with-cache.sh` automates that pairing for the common
case of building a "base" ref first and a "target" ref against it —
e.g. seeding the cache from `master` and building a PR branch against
it, so the PR build only recompiles what the PR actually touches:

```
scripts/build-with-cache.sh \
  ".#nix-incremental" --override-input nix github:NixOS/nix/master \
  -- \
  ".#nix-incremental" --override-input nix github:NixOS/nix/pull/16428/merge
```

It mirrors every `--override-input` given to the base build onto
`cache/<name>` for the target build, so `cache` is evaluated with the
exact inputs base was actually built with — not a `follows`, which
would be wrong here: base and target are supposed to use different
`nix` revisions, and a `follows` would silently force them to match.

Also runnable without a checkout, as `apps.<system>.build-with-cache`:

```
nix run github:tomberek/incremental#build-with-cache -- \
  ".#nix-incremental" --override-input nix github:NixOS/nix/master \
  -- \
  ".#nix-incremental" --override-input nix github:NixOS/nix/pull/16428/merge
```

For the common case of comparing two revs of *one* input (this is
that same pairing, just for a single named input instead of
mirroring an arbitrary list of overrides), `build-input-diff.sh` /
`apps.<system>.build-input-diff` is shorter:

```
nix run github:tomberek/incremental#build-input-diff -- \
  .#nix-all-components nix github:NixOS/nix/master github:NixOS/nix/pull/16428/merge
```

Measured on `nix-util`/`nix-store` (cold vs. a same-source rebuild
restoring 100%-hit ccache state): 44s → 17s and 101s → 36s
respectively — roughly a 2.6-2.8x speedup. A real PR pays full price
for whatever it actually touches; everything else gets this speedup.
Components that `#include` a changed component's headers (e.g.
`nix-expr` including `nix-fetchers`) recompile too, since their
`-isystem` flag now points at a different (also-changed) `-dev`
store path — a real cost, not a cache misconfiguration.

Three adjustments from NixOS/nix's own defaults:

- `withUnityBuild = false` — Meson's unity-build feature merges many
  `.cc` files into one translation unit, coarsening ccache's per-file
  hit granularity to uselessness.
- `withAWS = false` on `nix-store` — its `aws-crt-cpp` dependency
  resolves via CMake, whose compiler-detection breaks under a fully
  swapped `ccacheStdenv`.
- `CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime`
  — `random_seed` is the same `-frandom-seed` fix `hello-ccache`
  applies. `include_file_mtime`/`include_file_ctime` disable ccache's
  "recently modified" safety check on headers, since every dependency
  is materialized fresh into the sandbox every build.

## What's safe to cache

Each package points a tool's own cache dir (or file) at the restored
`incremental` output and lets the tool decide what to reuse. Safe
when these caches are content-addressed: ccache keys on preprocessed
source + flags, Go/Zig's build caches similarly, and autoconf's
`config.cache` stores check results ("does `malloc` exist? yes")
with no path baked in.

Not every tool defaults to this. Cargo's own build cache is
mtime-based, not content-addressed, and needs `-Zchecksum-freshness`
turned on explicitly before it's safe to restore this way — see
"Rust" above and `rust-staleness-self-test` in "Checks" below.

Caching `./configure`'s actual *output* — `config.status`, the
generated `Makefile`, `config.h` — isn't safe and isn't done here.
Autotools bakes the configure-time prefix into `config.status`/
`Makefile` as text, and for gettext-style builds directly into the
compiled binary (`-DLOCALEDIR=...`). Restoring a cached `Makefile`
against a new `$out` breaks the install or ships a binary pointing at
a stale store path.

Tried and dropped: relocating a fixed placeholder prefix by
byte-preserving find/replace (breaks on LTO sections and libtool
symlinks; also Nix normalizes unpacked-source mtimes, so `make` can
lose its own staleness check and silently keep a stale object), and
caching only autoreconf's output (misses `m4_esyscmd`-derived version
strings, e.g. gnulib's `git-version-gen`).

For compile-level caching beyond `config.cache`, use `ccacheStdenv`
rather than trying to skip `./configure`.

See `checks/README.md` for what `nix flake check` and
`scripts/verify-override-input.sh` actually test.

## Chained rebuilds don't produce their own `incremental` output

A plain build always produces an `incremental` output — what a later
build restores from. A build that's itself restoring from an injected
`cache` defaults to not producing its own, to avoid leaving a
redundant cache blob on top of the one just read.

Pass `keepIncremental = true` to opt back in (e.g. to keep chaining
further). `hello-ccache` and every `nix-*` component always keep it —
`hello-ccache` because `--cache-file` needs a real declared output to
resolve; `nix-*` components because that's what makes the per-target
caching above work at all.
