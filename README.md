# Incremental builds

Reuse outputs/caches from a previous build by overriding the `cache`
flake input to an earlier checkout (or a previous build, or whatever
ref you want).

```
$ nix build .#golang
echo "// hi" >> golang/main.go
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#golang
```

## Zig

```
$ nix build .#zig
echo "// hi" >> zig/main.zig
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#zig
```

## ccache (hello-ccache)

```
$ nix build .#hello-ccache
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#hello-ccache
```

`hello-ccache` also caches autoconf's check results via
`--cache-file`: `nix build -L` shows `configure: loading cache
.../config.cache`, plus a ccache hit rate on rebuild.

## Adding a new ccache-cached package

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

For anything ccache alone doesn't cover — autoconf's `--cache-file`,
a second cache like Go's module cache — compose
`mkIncrementalPackage`/`mkIncrementalAutotoolsPackage` directly.

## NixOS/nix itself (nix-incremental)

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
because these caches are content-addressed: ccache keys on
preprocessed source + flags, Go/Zig's build caches similarly, and
autoconf's `config.cache` stores check results ("does `malloc` exist?
yes") with no path baked in.

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
      packages.x86_64-linux.default = incremental.lib.mkIncrementalPackage {
        name = "myapp";
        system = "x86_64-linux";
        inherit pkgs; # supplies nuke-refs
        cacheVars = [ "GOCACHE" ];
        phase = "postConfigure";
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
$ nix run github:tomberek/incremental#with-cache -- \
    "git+file://$PWD?rev=HEAD#packages.x86_64-linux.default" \
    "git+file://$PWD?rev=<pre-edit-commit>"
```

`withCache` requires a rev-pinned ref (`?rev=<sha>`, not `?ref=HEAD` or a
branch name) — `builtins.getFlake` only resolves locked refs under pure
eval, so this needs no `--impure`.

The `with-cache` app is just this, spelled without `--impure --expr`:

```
nix build --expr \
  'let pkg = builtins.foldl'"'"' (acc: a: acc.${a})
       (builtins.getFlake "<flake-ref>") ["packages" "x86_64-linux" "default"];
   in pkg.withCache "<cache-flake-ref>"'
```

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
