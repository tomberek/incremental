# nixgg architecture

nixgg is a gg-style build accelerator that treats every `-c` compile,
`ar` archive, and link invocation as a **content-addressed derivation**
in the Nix store. Rebuilds hit the cache when the inputs — source
content, flags, wrapper env, toolchain paths — are byte-identical to a
previous build, regardless of when or where.

This doc explains how the pieces fit together and what each cache is
for.

## Two-line summary

- **Shims** replace `cc` / `c++` / `ar` on PATH; each shim writes a
  Nix expression describing the intended derivation and either
  realises it immediately (**realise mode**) or leaves a symlink to
  the expression for later realisation (**placeholder mode**).
- **Local staging + per-TU tid markers** turn "compile this file"
  into a cache lookup: if nothing about the compilation has changed
  since last time, we skip `nix build` entirely and relink the output
  to the same store path.

## Top-level layout

```
nixgg/
├── nixgg                    single-command CLI (run/eval/force/build/emit/stats/env)
├── nix-make                 wraps `make` — discovers targets, calls `nixgg build`
├── nix-ninja                wraps `ninja` — same, resolves via `ninja -t query`
├── nix-cmake                wraps `cmake --build` — dispatches to nix-make/nix-ninja
│
├── lib.sh                   shared bash helpers sourced by every driver
├── compile-driver.sh        per-TU: parse argv → scan headers → stage → thunk/realise
├── link-driver.sh           links: classify inputs → thunk/realise
├── ar-driver.sh             archives: same shape
├── scan-headers.sh          gcc -MM -MG wrapper: emits <abs>\t<staged-rel>
│
├── shims/                   symlinked onto PATH via `nixgg env`
│   ├── _dispatch.sh         sourced by every shim: expands @rspfile args
│   ├── cc  gcc  c++  g++    if argv contains -c → compile-driver, else link-driver
│   ├── ar   ranlib          → ar-driver
│
├── nix/                     realised as store package "nixgg-nix"; imported by thunks
│   ├── builder.nix          per-TU CA derivation (compile)
│   ├── linker.nix           link CA derivation
│   ├── archiver.nix         ar CA derivation
│   ├── pure-store-path.nix  pure-eval-safe replacement for builtins.storePath
│   └── toolchain.nix        generated: pinned compiler/bash/coreutils store paths
│
├── flake.nix / flake.lock   nixpkgs + PR-15793 pins; produces env-shell + nixgg-nix
├── example/                 toy Makefile smoke test (main.cc + util.cc + util.h)
├── mosh.sh redis.sh fmt.sh  real-world integration scripts
└── README.md ARCHITECTURE.md
```

## Working directory: `.nixgg/`

Every project (or subdirectory that gets a shim invocation) accumulates
a `.nixgg/` tree in whatever directory make happens to be running in.
Four subdirectories, each a distinct cache with a well-defined key and
invalidation:

```
.nixgg/
├── thunks/     ← per-derivation Nix expression files
│   ├── <thunk-id>.nix                   the expression itself
│   ├── .tid.<tu-id>          marker: last-known thunk-id + built store path
│   ├── .argv.<argv-hash>     first-tier compile cache: same argv → same store path
│   └── .link.<argv-hash>     first-tier link cache: same argv+inputs → same store path
├── srcs/       ← per-TU staging dirs (hardlinks to source + headers)
├── scans/      ← cached scan-headers.sh output
└── symlinks/   ← manifest: thunk-id → caller-visible symlink paths
```

The `.argv.<hash>` markers are what makes warm rebuilds fast — hashing
argv is cheap, and a hit means we can skip scan-headers, staging, and
expression building entirely.

### `thunks/<id>.nix`

**One file per unique derivation** we've ever asked for in this project.
`<id>` is `sha256(expression-body)[:32]` — content-addressed by the Nix
expression itself. Same expression → same id → same file, so writing is
idempotent.

Content is a single `import <helper> { … };` call with named args:

```nix
import /nix/store/…-nixgg-nix/builder.nix {
  toolBasename   = "gcc";
  srcTree        = ../srcs/ae;
  source         = "src/ae.c";
  outName        = "ae.o";
  flagsJSON      = ''["-O3","-Wall",…]'';
  storeDepsJSON  = ''[]'';
  wrapperEnvJSON = ''{}'';
}
```

- Toolchain roots are *not* in the thunk — they live in
  `nixgg-nix/toolchain.nix` and are picked up by default-arg fallback
  inside the helpers.
- `srcTree` is a Nix path expression (`../srcs/<tu-id>`), which Nix
  resolves relative to the thunk file's own directory and imports into
  the store at eval time. No `nix store add` in the shim.
- Sibling thunks are referenced by relative path too:
  `inputs = [ { drv = import ./<sibling-id>.nix; name = "foo.o"; } … ]`,
  which keeps thunk content cwd-independent.

**Key**: sha256 of the expression body.
**Invalidation**: any change to flags, source name, output name,
included store deps, wrapper env, or the referenced helper store path
(`import /nix/store/…-nixgg-nix/…`).

Also lives here: **`.tid.<tu-id>`** — a one-line file
`<thunk-id>\t<built-store-path>` written by compile-driver after a
successful realise. Read on the next shim invocation to decide "same
inputs as last time?" — if so, skip `nix build` entirely and relink
the output.

And **`.argv.<argv-hash>`** — a one-line file
`<thunk-id>\t<built-store-path>\t<scan-cache-key>`. This is the
*first-tier* short-circuit: hashing argv is cheap, and a matching
entry lets us skip scan-headers, staging, and expression building
altogether — as long as the referenced scan cache is still valid
(mtimes on every header match) AND the recorded store path still
exists. See "Flow" section below for how it slots in.

### `srcs/<tu-id>/`

**One dir per translation unit**, populated with **hardlinks** to the
source file plus every header discovered by `scan-headers.sh`.
Structure inside mirrors the "project root" the scanner picked
(typically the common ancestor of `cwd` and every user-supplied `-I`
directory).

`<tu-id>` is a filesystem-safe slug of the compile's output path:
`src/foo/bar.o` → `src-foo-bar`. Stable across rebuilds of the same
TU; two different TUs never collide.

The staging dir is the value of `srcTree` in the corresponding thunk —
Nix walks the dir, NAR-hashes it, imports it into the store at build
time. If two TUs share `util.h`, they share the underlying inode via
their hardlinks; when Nix imports each `srcs/<tu-id>/`, its per-file
dedup notices identical content.

**Key**: `<tu-id>` = slug of output path.
**Reuse check**: for every (abs-path, staged-relpath) pair, `stat`
both and compare inodes. Hardlinks share an inode with the original, so
inode-match ⇔ "the original wasn't rewritten since we linked it."
Additionally check that the set of files in the staging dir matches the
current header list (catches header removals).
**Invalidation**: any inode mismatch, or any file present in one set
but not the other → `rm -rf` the dir and repopulate.

### `scans/<key>.{out,err,deps}`

**Cache of `scan-headers.sh` output**. `<key>` = 32-char sha256 of
`(real_cc, source, flags)`.

- `.out`: captured stdout — one `<abs>\t<staged-rel>` line per header.
- `.err`: captured stderr — `PROJECT_ROOT=`, `STAGED_IFLAG=`,
  `STORE_IFLAG=` lines the driver consumes.
- `.deps`: `<abs>\t<mtime>` per file the scan referenced (source +
  every header). Read on next lookup to decide "any input's mtime
  advanced?"

**Key**: sha of the (compiler, source, sorted flags) triple.
**Invalidation**: if any file in `.deps` has an mtime newer than the
recorded one, or is missing, re-run the scanner.

Motivation: `gcc -MM -MG` is the dominant per-shim cost after we
stopped calling `nix store add`. A no-op rebuild that hits this cache
skips the compiler fork entirely.

### `symlinks/<thunk-id>`

**Manifest** mapping "this thunk" → "every caller-visible file that
points at it." One line per symlink, absolute paths, append-only.

Written by `nixgg::link_placeholder` (placeholder mode) and
`nixgg::link_store_to_output` (realise mode). Read by `nixgg force`
and `nixgg force --roots`:

- **`nixgg force <target>`** walks the transitive `import ./<id>.nix`
  graph starting from `<target>`'s thunk, and for each visited thunk
  promotes every symlink in its manifest from `→ thunks/<id>.nix` to
  `→ /nix/store/…-tu-<name>/…`. That's how "realise one target"
  realises its whole DAG — no filesystem sweep, no per-file guessing.
- **`nixgg force --roots`** picks any thunk-id not referenced by
  another thunk's `import ./<id>.nix` and forces one of its
  symlinks. Handles build systems that hide outputs from `make -n`
  (cmake's `cmake_link_script` invoking `ar`, for example).

**Key**: thunk-id.
**Invalidation**: none needed — append-only; stale entries (user
deleted the file) are filtered by `[[ -L "$sym" ]]` at read time.

## Nix store: the actual derivation cache

Every `-tu-<name>`, `-bin-<name>`, `-ar-<name>` in the Nix store is a
content-addressed output. CA hash covers: the toolchain binary, the
compile invocation, the source tree Nix imported (which was our
`srcs/<tu-id>/`), every flag, every wrapper env var. Change one bit
of any input → different CA hash → cache miss (correct) → Nix builds.
Identical inputs → same CA hash → Nix returns the pre-existing store
path without rebuilding.

GC roots for these outputs are registered under
`<store>/nix/var/nix/gcroots/per-user/$USER/nixgg/<sha1-of-target-path>`
by `nixgg::_register_gcroot`, so `nix-store --gc` preserves anything a
live caller-visible symlink still points at.

## Flow: one shim invocation, `cc -c ae.c -o ae.o -O3 …`

```
make → cc (shim on PATH)
  ├── shims/cc sources shims/_dispatch.sh (expands @rspfile if any)
  ├── sees "-c" in argv → exec compile-driver.sh cc ...
  │
  └── compile-driver.sh:
      1. Parse argv → source="ae.c", output="ae.o", flags=[…]
      2. argv_hash = sha256(TOOL + argv) — cheap
         read .argv.<argv_hash>       → cached tid + built + scan_key
         if scan_cache_fresh(scan_key) — batch stat on .deps
             AND cached built path exists
             → argv-cache hit: relink ae.o → cached built, exit ✓
      3. scan_headers_cached           → header list + PROJECT_ROOT + iflags
      4. stage_sources                 → inodes match? reuse. Else rebuild.
      5. Assemble Nix expr             → import .../builder.nix { … }
      6. tid = sha256(expr)
         read .tid.ae                  → old tid, old built-store-path
         if old_tid == tid             → tid-cache hit: relink and refresh
             AND old_built exists         .argv.<argv_hash>, exit ✓
      7. placeholder mode?             → write thunks/<tid>.nix, symlink
                                          ae.o → thunk, exit
      8. realise mode:                 → nix_build_expr → nix build --file
                                          relink ae.o → /nix/store/…-tu-ae.o
                                          write .tid.ae + .argv.<argv_hash>
                                          register gcroot
```

Hot path in warm state: steps 1-2 fire the argv-cache and exit before
we ever touch scan-headers or the filesystem beyond one `stat` batch.
That path is ~15ms in shell. On a redis warm rebuild all ~120 TU
shims take this branch.

Slower fallbacks:
- Step 6 (tid-cache): fires when argv-cache missed but staging /
  scan-headers still produce byte-identical inputs. Cost: everything
  in steps 3-5 (~100ms) but no `nix build`.
- Step 8: the full path, ~200ms of shell + however long `nix build`
  takes to evaluate + build.

## Modes

- **`realise` (default)** — each shim runs `nix build` and re-points the
  output symlink at `/nix/store/…`. Simple, always correct;
  per-invocation Nix startup cost.
- **`placeholder`** — each shim writes `thunks/<id>.nix` and symlinks
  the output at it. `make` sees a file, moves on. A final
  `nixgg force <target>` (or `--roots`) walks the transitive `import`
  graph and realises the whole DAG in one Nix invocation.

Both modes produce **bit-identical CA store paths** for identical
inputs — the mode only affects *when* the realisation happens.

## What every input to the CA hash is

For a compile:

- Compiler binary content (via `compilerRoot` → pinned by `flake.lock`)
- `toolBasename` (which of cc/gcc/c++/g++ to invoke inside)
- `srcTree` content (NAR-hash of `srcs/<tu-id>/`)
- `source` relative path inside srcTree
- `flags` list (order-preserved, JSON-encoded)
- `wrapperEnv` (NIX_CFLAGS_COMPILE, NIX_LDFLAGS, etc — from Nix's gcc-wrapper)
- `storeDeps` (any `/nix/store/…` roots referenced by flags/env)
- bash + coreutils (baked into builder.nix at nixgg-nix realise time)

The staging (`srcs/<tu-id>/`) is what makes step 3 tractable: instead
of NAR-hashing every source + header on each shim invocation, we let
Nix compute that hash exactly when it needs to (on `nix build`), and
we short-circuit before ever getting there when nothing changed.

## Flake toolchain pin

`flake.nix` produces:

- **`env-shell`**: a sourceable `export NIXGG_… = /nix/store/…` block.
  Sources on first `nixgg` invocation; caches into the alt store.
- **`nixgg-nix`**: `nix/` copied into the store plus a generated
  `toolchain.nix` with the pinned compiler/bash/coreutils roots.
  Every thunk `import`s from this path.
- **`mosh-env` / `fmt-env`**: `nix develop` shells with the deps
  needed to build mosh and fmt respectively; used by the integration
  scripts.
- **`patched-nix`**: PR 15793's `nix` binary. Only used by
  `nixgg emit`'s `.sandboxed` variant.

Alt store: default `local?root=/tmp/nixgg-store`. Override with
`ALT_STORE=…`.

## Activity log

If `NIXGG_LOG=<path>.ndjson` is set, every shim appends one JSON line
per invocation: `event` (compile/link/ar), `kind`
(cache_hit/thunk/derivation/passthrough), tool, source, output,
resulting store path, elapsed wall clock, and a cache-hit heuristic.
`nixgg stats <log>` summarises.

Types of events emitted:

- `argv_cache_hit` — first-tier short-circuit fired. Zero real work,
  no scan-headers, no staging. Just relink.
- `cache_hit` — second-tier short-circuit fired (thunk id matched
  even though argv-cache missed). Scan-headers + staging ran; the
  `nix build` was skipped.
- `thunk` — placeholder mode wrote a thunk and symlinked.
- `derivation` — realise mode invoked `nix build` and got a store
  path (either fresh build or Nix eval-cache hit).
- `passthrough` — the invocation wasn't something nixgg models (not
  a single-TU compile, no `-c`, weird link, etc); real cc/ar ran.

## What we don't do

- **No configure/autoconf modelling.** Configure phases run in
  realise mode via `nixgg run --` because probes like autoconf's
  `conftest.c` need real file outputs synchronously.
- **No cross-project cache sharing today.** `.nixgg/` lives at
  `$PWD/.nixgg/` per-project. Two projects that #include the same
  system header get separate staging dirs. The Nix store itself does
  content-dedup, so this is mostly cosmetic.
- **No sandbox environment scrubbing.** Timestamps, hostnames, and
  build IDs baked into source (like redis's `mkreleasehdr.sh`) leak
  through and cause top-level link CA-cache misses. Users can pin
  `SOURCE_DATE_EPOCH` etc. themselves; we don't try to fix it
  automatically.
