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

