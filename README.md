# Incremental builds

Reuse outputs/caches from a previous build by overriding the `cache`
flake input to an earlier checkout (or a previous build, or one from
a given date — whatever ref works for you).

```
# Build normally.
$ nix build .#golang

# make a change to the source code
echo "// hi" >> golang/main.go

# rebuild of the dirty tree is faster
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
`--cache-file`. `nix build -L` shows `configure: loading cache
.../config.cache` and a ccache hit rate on rebuild.

## NixOS/nix itself (nix-incremental)

`github:NixOS/nix`'s flake splits the `nix` package into ~14
Meson/Ninja component derivations (`nix-util`, `nix-store`,
`nix-expr`, ...) rather than one monolithic build. Its flake exposes
`nix.lib.makeComponents` + `overrideAllMesonComponents`, an
overlay-shaped seam applied to every component transitively —
building `nix-cli` also applies it to everything underneath. This
repo's `mkIncrementalNixComponents` (in `flake.nix`) uses that seam to
give every component its own restored ccache dir, the same as
`hello-ccache`.

```
$ nix build .#nix-incremental
# edit a .cc file under a local NixOS/nix checkout, or just rebuild as-is
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nix-incremental
```

Each component (`nix-util`, `nix-store`, `nix-fetchers`, `nix-expr`,
`nix-flake`, `nix-main`, `nix-cmd`, and their `-c` C-API variants) is
also exposed as its own top-level package, since
`mkIncrementalNixComponents` restores each one's cache independently
— `nix build .#nix-util` works standalone.

Two adjustments from NixOS/nix's own defaults, needed to make this
work:

- `withUnityBuild = false` — Meson's unity-build feature (on by
  default) merges many `.cc` files into one translation unit before
  compiling, which coarsens ccache's per-file hit granularity to the
  point of being nearly useless. NixOS/nix's own dev shell already
  disables this for the same reason.
- `withAWS = false` on `nix-store` — pulls in `aws-crt-cpp`, resolved
  via CMake; CMake's own compiler-detection probes break under a
  fully swapped `ccacheStdenv`. Not needed for this demo.

And the same `-frandom-seed` fix as `hello-ccache`
(`CCACHE_SLOPPINESS=random_seed`) — nixpkgs' cc-wrapper adds a fresh
random seed flag to every compiler invocation, which would otherwise
make every single compile a guaranteed cache miss.

## What's safe to cache

Each package points a tool's own cache dir (or file) at the restored
`incremental` output and lets the tool decide what to reuse. Safe
because these caches are content-addressed: ccache keys on
preprocessed source + flags, Go and Zig's build caches similarly, and
autoconf's `config.cache` stores check results ("does `malloc` exist?
yes") with no path baked in. None of it references this build's
`$out`.

Caching `./configure`'s actual *output* — `config.status`, the
generated `Makefile`, `config.h` — isn't safe, and isn't done here.
`$out` is a unique store path that changes whenever the source
changes, but autotools bakes the configure-time prefix into
`config.status`/`Makefile` as text, and for gettext-style builds
(GNU Hello included) directly into the compiled binary via
`-DLOCALEDIR=...`. Restoring a cached `Makefile` against a new `$out`
either breaks the install or ships a binary pointing at a store path
that no longer exists.

A few workarounds were tried and dropped: relocating a fixed
placeholder prefix by byte-preserving find/replace (breaks on LTO
object sections and libtool symlinks), sed-rewriting the old `$out`
to the new one across the build tree (same breakage, plus Nix
normalizes unpacked-source mtimes to a single value, so `make` can
tie/lose its staleness check and silently keep a stale object), and
caching only autoreconf's output (misses `m4_esyscmd`-derived version
strings, e.g. gnulib's `git-version-gen`, which GNU Hello uses).

`hello-ccache`'s `config.cache` caching is the safe subset — it never
restores a compiled artifact or path-bearing file. See
`mkIncrementalAutotoolsPackage` in `flake.nix`. For compile-level
caching beyond that, use `ccacheStdenv` rather than trying to skip
`./configure`.

## Chained rebuilds don't produce their own `incremental` output

Building plain (no `cache` override) always produces an `incremental`
output — that's what a later build restores from. But once a build
is *itself* already restoring from an injected `cache` (i.e. you
passed `--override-input cache ...`), it defaults to **not**
producing its own `incremental` output — it still gets the full
benefit of the restored cache (real ccache/GOCACHE/Zig-cache hits),
it just doesn't leave behind a second, almost-never-read cache blob
on top of the one it read from. Chaining `--override-input cache`
three levels deep would otherwise leave three redundant multi-hundred-
MB blobs in the store for no benefit.

If you genuinely want to keep chaining past a restored build (e.g.
build A, then B from A, then C from B, each hop the actual source of
the next), pass `keepIncremental = true` to `mkIncremental` /
`mkIncrementalPackage` for that call site to opt back in.

`hello-ccache` is the one exception: it always keeps `incremental`,
because `--cache-file` is wired via a Nix-level
`builtins.placeholder "incremental"` substitution that requires a
real declared output to resolve, unlike the plain env-var caches
(ccache/Go/Zig), which have a scratch-dir fallback to opt out into.

