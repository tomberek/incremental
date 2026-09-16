# Incremental builds

Reuse outputs/caches from a previous build by overriding the `cache`
flake input to an earlier checkout, a previous build, or any git ref.
Point a tool's own cache dir at a restored `incremental` output and
let the tool decide what's still valid — this repo does the
restoring, not the deciding.

## Results

- **Biggest wins**: OpenCV 4.4x, LLVM's `buildPhase` 26x (98% ccache
  hits), Kubernetes 3.4x, Nushell's `buildPhase` from ~7m40s to 1.3s
  (0/588 crates recompiled). Full numbers in "Real nixpkgs packages"
  below.
- **Patches only invalidate what they touch** — from jq's one-line
  patch up to nushell's 588-crate workspace and protobuf's 360
  translation units. A patch to a widely-`#include`d header (fmt,
  protobuf) costs far more — the same tradeoff any C/C++ build makes,
  cached or not.
- **GHC's own incremental mechanism just works.** Unlike Cargo
  (mtime-based, needs an explicit fix — see "What's safe to cache"),
  GHC's `previousIntermediates` correctly detects real source changes
  under Nix's epoch-normalized mtimes with no extra work.
- **ccache isn't universal.** `curl`, `openssh`, `emacs`, and `gcc`
  each get ~0% real benefit, for different structural reasons — see
  "ccache isn't universal" below.

## Using this as a library from another flake

`--override-input` requires the flake being built to declare `cache`
as an input, which means a third party has to edit their own
`flake.nix` just to opt in. So every `mkIncremental`-based derivation
also carries `passthru.withCache`: a plain function that takes a
rev-pinned flake ref and returns the same package restoring from that
build — no `--override-input`, no changes to the caller's `flake.nix`:

```nix
# their flake.nix — no inputs.cache needed
{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.incremental.url = "github:tomberek/incremental";
  outputs = { self, nixpkgs, incremental, ... }: {
    packages = builtins.mapAttrs (system: pkgs: {
      default = incremental.lib.mkIncrementalGoPackage {
        name = "myapp";
        inherit system pkgs; # pkgs supplies nuke-refs
        drv = pkgs.buildGoModule {
          pname = "myapp";
          version = "0.1.0";
          src = ./.;
          vendorHash = "...";
        };
      };
    }) nixpkgs.legacyPackages;
  };
}
```

```
$ nix build .#default   # also produces .#default.incremental
echo "// x" >> main.go
$ nix run github:tomberek/incremental#with-cache -- .
```

`with-cache` takes a baseline first, then the target to build against
it (target defaults to `.#default`). The baseline is auto-pinned to
its locked rev if it isn't already, so a plain local path or branch
name works too:

```
$ nix run github:tomberek/incremental#with-cache -- \
    "git+file://$PWD?rev=<pre-edit-commit>" ".#default"
```

`passthru.asCacheApp` is the same call with the baseline pre-filled to
the current build's own source — useful when there's no flake ref to
type out:

```
nix run <this-flake>#default.passthru.asCacheApp -- <target-flake-ref>#<name-or-attrpath>
```

`mkIncrementalGoPackage`, `mkIncrementalZigPackage`,
`mkIncrementalSwiftPackage`, and `mkIncrementalRustPackage` bake in
the right `cacheVars`/`phase` for those ecosystems (see "Examples in
this repo" for why each needs what it needs). `mkIncrementalHaskellPackage`
wires up nixpkgs' own incremental mechanism instead of building one.
`mkIncrementalCcachePackage` does the same for ccache — pass
`autotools = true` to also cache `./configure`'s checks via
`--cache-file`. For anything else, compose
`mkIncremental`/`mkIncrementalAutotoolsPackage` directly.

## Examples in this repo

### Go / Zig / Swift / Rust

```
$ nix build .#golang && echo "// hi" >> golang/main.go
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#golang
```

Same shape for `.#zig` (`zig/main.zig`), `.#swift`
(`swift/Sources/swift-example/main.swift`), and `.#rust`
(`rust/src/main.rs`). Go's `buildGoModule` sets `$GOCACHE` in its own
`configurePhase`, so the restore hooks `postConfigure`. Zig's
`zigConfigurePhase` reassigns `ZIG_GLOBAL_CACHE_DIR` but never
`ZIG_LOCAL_CACHE_DIR`, so both are exported earlier, in `preConfigure`.
`swift build` has no env var at all for its scratch directory — only a
`--scratch-path` CLI flag — so `mkIncrementalSwiftPackage` exports the
restored path as `$SWIFTPM_SCRATCH_PATH` and the package's own build/
install phases pass it through explicitly. `.#nixpkgs-kubernetes`
uses the same `mkIncrementalGoPackage` unchanged against a real, much
bigger Go package (`pkgs.kubernetes`) — see "Real nixpkgs packages"
for the numbers.

Rust needs more: `buildRustPackage`'s `cargoInstallHook` looks for a
fixed *relative* path (`target/<subdir>/<buildType>`), not
`$CARGO_TARGET_DIR`, so `mkIncrementalRustPackage` symlinks `./target`
to the restored dir instead of exporting an env var. See "What's safe
to cache" for the mtime issues Cargo needs on top of that.
`.#nixpkgs-nushell` is the "go bigger" Rust test, a real ~50-crate
Cargo workspace (`pkgs.nushell`) instead of the toy example's single
crate — see "Real nixpkgs packages" for the numbers.

### Haskell (`.#haskell`, `pkgs.haskellPackages.pandoc-cli`)

```
$ nix build .#haskell
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#haskell
```

Unlike every other ecosystem here, this one needed no restore script
or staleness fix: nixpkgs' own Haskell builder already has a
first-class incremental mechanism. Pass `previousIntermediates` (a
prior build's `intermediates` output) and it splices `dist/build` back
in during `buildPhase`, before Cabal/GHC's own recompilation-avoidance
decides what's stale. `mkIncrementalHaskellPackage` turns that on via
`haskell.lib.compose.overrideCabal` — the only layer that works, since
`doInstallIntermediates`/`enableSeparateIntermediatesOutput` are
constructor args to `mkDerivation`, computed before the final attrset
exists, so a plain `.overrideAttrs` silently produces no
`intermediates` output at all. Restoring a same-source cache skips
compiling every one of pandoc's own modules — only the final relink
runs.

### ccache (`hello-ccache`, `c`)

```
$ nix build .#hello-ccache
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#hello-ccache
```

`mkIncrementalCcachePackage` is the one-call-site way to add ccache to
a C/C++ package — `c/` is the minimal worked example (no build system,
just `$CC` calls); `hello-ccache` is the `autotools = true` worked
example, which also caches autoconf's check results via
`--cache-file` (`nix build -L` shows `configure: loading cache
.../config.cache`):

```nix
c = mkIncrementalCcachePackage {
  name = "c";
  inherit system pkgs;
  phase = "postPatch"; # whichever phase runs before your compiler does
  drv = pkgs.ccacheStdenv.mkDerivation { ... };
};

hello-ccache = mkIncrementalCcachePackage {
  name = "hello-ccache";
  inherit system pkgs;
  autotools = true; # fixes phase to postPatch, adds --cache-file
  drv = pkgs.hello.override { stdenv = pkgs.ccacheStdenv; };
};
```

Two things that bite: `drv` must already be built with `ccacheStdenv`
(`.override { stdenv = pkgs.ccacheStdenv; }` on an existing package —
swapping `stdenv` after construction doesn't work, and an eval-time
assert catches this). `phase` must be a hook that still runs given
whatever the package skips (`postPatch` always does; `preConfigure`
doesn't if `dontConfigure = true`). `nuke` (scrub real store-path
references out of ccache's own manifest before it lands in
`incremental`) defaults to `false` — fine for a build this small, but
the real nixpkgs examples below pass `nuke = true` once a build is big
enough to pick up real references.

### Real nixpkgs packages

The toy examples above check the mechanism; these check viability on
something real. Every number is a measured same-source cold→warm
rebuild:

| package | mechanism | hit rate | speedup |
|---|---|---|---|
| `nixpkgs-jq` | autotools + ccache | 95% | 38s → 22s (~1.7x) |
| `nixpkgs-redis` | ccache only (no `./configure`) | 96% | 4m46s → 42s (~6.8x) |
| `nixpkgs-tmux` | autotools + ccache | 100% | 2m → 1m13s (~1.6x) |
| `nixpkgs-python3` | ccache only | 99% | 4m16s → 3m24s (~1.2x) |
| `nixpkgs-perl` | ccache only (`Configure`, not autoconf) | 99% | 2m57s → 1m48s (~1.6x) |
| `nixpkgs-llvm` | ccache only (CMake/Ninja) | 98% | buildPhase 35m17s → 1m20s (~26x); overall 10816s → 2377s (~4.5x) |
| `nixpkgs-fmt` | ccache only (CMake) | 98% | ~87s → ~12s (~7x) |
| `nixpkgs-protobuf` | ccache only (CMake) | — | buildPhase ~6m cold; `doCheck` disabled (own test suite alone runs 15m+) |
| `nixpkgs-opencv` | ccache only (CMake) | 99% | 27m26s → 6m14s (~4.4x) |
| `nixpkgs-kubernetes` | `mkIncrementalGoPackage` (`$GOCACHE`, no ccache) | — | 14m43s → 4m17s (~3.4x) |
| `nixpkgs-nushell` | `mkIncrementalRustPackage` (~50-crate workspace) | 0/588 crates recompiled | buildPhase ~7m40s → 1.3s |

```
$ nix build .#nixpkgs-jq
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-jq
```

Same shape for every package above. `nixpkgs-llvm`, `nixpkgs-opencv`,
`nixpkgs-kubernetes`, and `nixpkgs-nushell` aren't run in CI — their
cold builds take 35+, ~27, ~15, and ~11 minutes locally, too slow for
every push. `nixpkgs-kubernetes` and `nixpkgs-nushell` have no
hit-rate percentage because they're not ccache-based (`$GOCACHE` and
Cargo respectively), so wall-clock or crates-recompiled is reported
instead.

100% cache hits doesn't mean proportionally faster. `tmux` hits 100%
but only gets ~1.6x, and LLVM's `buildPhase` speedup (~26x) doesn't
carry through to its overall wall-clock (~4.5x) — `checkPhase` runs
LLVM's own `lit` test suite every build regardless of caching. It
means whatever ccache *can* see was fully reused; how much of the
wall-clock that actually is depends on the package. `python3` hits the
same pattern for a different reason: `postInstall` runs
`python -m compileall` over the entire stdlib three times, pure
bytecode compilation ccache never sees.

`redis`/`perl`/`llvm`/`fmt`/`protobuf`/`opencv` are ccache-only (no
`--cache-file`) because none has a real autoconf `./configure`: redis
is a plain Makefile, perl's own `Configure` isn't autoconf, llvm/fmt/
protobuf/opencv are CMake. `python3` does have a real `./configure`,
but its nixpkgs derivation restricts `outputChecks.out` from
referencing `openssl-dev`, and `--with-openssl=<path>-dev` in
`configureFlags` means `config.cache` would legitimately record that
path — tripping the check. Dropping `--cache-file` avoids that.

#### Patches, not just same-source reruns

Every `nixpkgs-*-patched` variant applies one small, real upstream
commit (see `patches/`) on top of the unpatched package, sharing its
cache key. Restoring from the *unpatched* build's cache and building
the *patched* one only recompiles what the patch touched:

```
$ nix build .#nixpkgs-jq
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-jq-patched
```

| patched package | patch | hits | vs. unpatched |
|---|---|---|---|
| `nixpkgs-jq-patched` | one line, `src/main.c` | 23/24 (95%) | same 95% |
| `nixpkgs-llvm-patched` | one function, `MemoryDependenceAnalysis.cpp` | 4075/4159 (97.9%) | 98.0% unpatched, ~4200 TUs |
| `nixpkgs-fmt-patched` | header fix, `include/fmt/format.h` | 17-20/54 (31-37%, varies by run) | 98% unpatched — every `.cc` includes the header |
| `nixpkgs-protobuf-patched` | leaf `.cc` + its header, `repeated_field.{cc,h}` | 104/360 (29%) on CI, 100/360 (27%) locally | same "widely-included header" cost, at 10x the scale |
| `nixpkgs-opencv-patched` | one line, `connectedcomponents.cpp` | 1855/1875 (98.9%) | 99.0% unpatched — a narrow leaf fix, not a header |
| `nixpkgs-kubernetes-patched` | one leaf file, `cmd/kubeadm/.../config.go` | — (Go, no hits) | 4m49s vs. 4m17s same-source — the other 5 built components weren't invalidated |
| `nixpkgs-nushell-patched` | one leaf file + its own test, `crates/nu-command/src/filesystem/umkdir.rs` | 584/588 unchanged (99.3%) | only the patched crate and its 3 dependents (`nu-cli`, `nu-lsp`, `nu`) recompiled |

A header change costs proportionally more than a leaf-file one — the
same tradeoff any C/C++ build makes, cached or not: `fmt`/`protobuf`'s
patches touch a header every translation unit includes, so most of
the build recompiles regardless of caching, while `jq`/`llvm`/
`opencv`'s patches touch one file only their own translation unit
depends on. `fmt`/`protobuf`'s exact hit counts also vary between CI
and a many-core local machine — see "What's safe to cache" for why.

#### ccache isn't universal

Tried and dropped, each confirmed by measurement:

- **`curl`**: 100% ccache hits, 0% real speedup — build time is
  man-page rendering, not compilation.
- **`openssh`**: 0% hits — bakes its own `$out` into `-D` flags
  (`-D_PATH_SSH_PROGRAM=...`), so every compile command differs
  between builds regardless of source changes.
- **`nginx`**: incompatible outright — its `./configure` isn't
  autoconf and rejects `--cache-file`.
- **`emacs`**: 1% hits (3/155) — native-lisp `.eln` compiles through
  `libgccjit` in-process during Emacs's own "dump" step, never through
  `$CC`. A structural blind spot for a compiler-wrapping cache, not a
  bug here.
- **`gcc`**: 0/0 ccache *invocations* — the same blind spot as emacs,
  just compiling itself instead of Lisp. GCC bootstraps its own
  compiler (`xgcc`) once with the host `$CC`, then uses that
  self-built `xgcc` — never the ccache wrapper — for the rest of the
  build. Warm was *slower* than cold (932s vs. 732s): ccache overhead
  with zero payoff.

### NixOS/nix itself (`nix-incremental`)

`github:NixOS/nix`'s flake splits `nix` into ~14 Meson/Ninja component
derivations sharing a scope via `overrideAllMesonComponents` — an
overlay applied to every component, so building the full CLI applies
it underneath too. Only the named target gets a cache-varying restore
script; every dependency gets a fixed one and falls back to plain
store substitution (a shared dependency's script varying with caching
state would give it a different derivation per `cache` input,
poisoning every dependent's `-isystem` flag into a permanent miss).

```
$ nix build .#nix-fetchers
# edit a .cc file, e.g. under a local NixOS/nix checkout
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nix-fetchers
```

`nix-incremental` builds the full CLI the same way. It hits **96%
(63/65)** on a same-source rebuild — that number needed one fix: the
restore matched on the component's own Meson `pname`, but `nix-cli`'s
real `pname` is `"nix"`, not `"nix-cli"`, so both the match *and* the
cache lookup used the wrong string, silently restoring from `"empty"`
regardless of `--override-input cache`. Fixed by separating `target`
(matches the real `pname`) from `name` (the cache lookup/report key,
defaults to `target` but overridable).

**Want every component to individually benefit, not just the one you
name?** Build `nix-all-components` instead — every component as its
own top-level target, each with its own restore script and hit rate:

```
$ nix build .#nix-all-components
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nix-all-components
```

The ccache summary prints top miss reasons from the debug log:

```
ccache[nix-fetchers]: 18/18 hits (100%)
```

**`--override-input nix <path>` needs `cache/nix` overridden too** —
`cache` resolves its own `nix` input from `flake.lock` independently:

```
nix build .#nix-fetchers \
  --override-input nix ~/my-nix-checkout \
  --override-input cache "git+file://$PWD?ref=HEAD" \
  --override-input cache/nix ~/my-nix-checkout \
  -L
```

`scripts/build-with-cache.sh` automates that pairing for comparing a
base ref against a target ref (e.g. seeding from `master`, building a
PR branch against it — mirrors every `--override-input` given to the
base build onto `cache/<name>` for the target, not a `follows`, since
base and target are supposed to use *different* revisions):

```
scripts/build-with-cache.sh \
  ".#nix-incremental" --override-input nix github:NixOS/nix/master \
  -- \
  ".#nix-incremental" --override-input nix github:NixOS/nix/pull/16428/merge
```

Also runnable without a checkout (`apps.<system>.build-with-cache`),
and `build-input-diff.sh`/`apps.<system>.build-input-diff` is the
shorter form for comparing two revs of one input:

```
nix run github:tomberek/incremental#build-input-diff -- \
  .#nix-all-components nix github:NixOS/nix/master github:NixOS/nix/pull/16428/merge
```

Measured on `nix-util`/`nix-store`: 44s → 17s and 101s → 36s
(~2.6–2.8x) restoring a 100%-hit cache. A real PR pays full price for
whatever it actually touches; components that `#include` a changed
component's headers recompile too — a real cost, not a
misconfiguration.

Three adjustments from NixOS/nix's own defaults: `withUnityBuild =
false` (unity builds merge many `.cc` files into one translation
unit, wrecking per-file hit granularity), `withAWS = false` on
`nix-store` (its CMake-resolved `aws-crt-cpp` dependency breaks under
a swapped `ccacheStdenv`), and
`CCACHE_SLOPPINESS=random_seed,include_file_mtime,include_file_ctime`
(`random_seed` is the same `-frandom-seed` fix `hello-ccache` needs;
the other two disable ccache's "recently modified" header check,
since every dependency is materialized fresh into the sandbox).

## What's safe to cache

**Content-addressed caches are safe to restore this way**: ccache keys
on preprocessed source + flags, Go/Zig's build caches similarly,
autoconf's `config.cache` stores check results with no path baked in.

**Cargo isn't** — its own staleness check is mtime-based, and Nix
normalizes every unpacked file's mtime to the epoch, so a restored
`target/` looks "fresh" regardless of what changed. Fixed with
Cargo's `-Zchecksum-freshness` (unlocked on stable via
`RUSTC_BOOTSTRAP=1`), switching it to content-hash staleness — the
same fix ccache needed, for the same reason.
`rust-staleness-self-test` (see `checks/README.md`) catches a
regression here by restoring a cache built from *different* source
and asserting the binary isn't served stale. Two more Cargo-specific
gotchas, both surfaced on `nixpkgs-nushell` (a ~50-crate workspace —
the toy `rust/` example has zero dependencies and never exercises
either path):

- `nuke-refs` corrupts compiled `build-script-build` ELF binaries —
  their dynamic linker interpreter path gets rewritten, and Cargo
  tries to re-execute the broken binary on the next build. Use
  `nuke = false` for Rust packages.
- The restore script copies a prior build's cache with `cp -r`, which
  stamps each file with the real time it's copied, in whatever order
  `cp` walks the tree. Cargo's cross-crate staleness check compares a
  dependency's mtime against its dependent's, so copy-order noise
  alone can cause spurious recompiles. Fixed by touching every
  restored file to one timestamp captured up front, rather than
  letting `cp`'s real-time stamps or Nix's frozen epoch mtimes leak
  through.

**`./configure`'s own output isn't safe to cache** — `config.status`,
the generated `Makefile`, `config.h`. Autotools bakes the
configure-time prefix into those as text (and for gettext-style
builds, directly into the compiled binary via `-DLOCALEDIR=...`);
restoring a cached `Makefile` against a new `$out` breaks the install
or ships a binary pointing at a stale store path. Byte-preserving
find/replace on a placeholder prefix breaks LTO sections and libtool
symlinks (and loses Make's own mtime-based staleness check, since Nix
normalizes source mtimes); caching only autoreconf's output misses
`m4_esyscmd`-derived version strings like gnulib's `git-version-gen`.
For compile-level caching beyond `config.cache`, use `ccacheStdenv`
instead of trying to skip `./configure`.

**`fmt`/`protobuf`'s hit-rate percentages vary between machines** —
CI (`ubuntu-latest`, 4 cores) and a many-core local machine reliably
disagree, and it's a ccache write race, not a correctness issue: the
restored build is identical either way, only the reported percentage
moves. fmt's own `test/CMakeLists.txt` compiles the same helper source
(`test/util.cc`, shared with `test-main.cc`/`gtest-extra.cc`) into 4
separate test executables that never share a library. Under enough
parallelism those 4 identical compiles can start within milliseconds
of each other, all find no existing manifest entry at once, and all
write independently — one hit collapses into several misses, but no
compile is actually invalidated. protobuf's `upb_generator` sources
have the same shape. Every other package here reproduces exactly
between CI and local runs because none of them compile one
translation unit into more than one target — this is specific to
fmt's and protobuf's own build graphs, not this repo's caching layer,
and the real fix belongs upstream (deduplicating those targets onto a
shared library, or ccache serializing first-write races).

See `checks/README.md` for what `nix flake check` and
`scripts/verify-override-input.sh` actually test.

## Chained rebuilds don't produce their own `incremental` output

A plain build always produces an `incremental` output — what a later
build restores from. A build that's itself restoring from an injected
`cache` defaults to not producing its own, to avoid leaving a
redundant cache blob on top of the one just read. Pass
`keepIncremental = true` to opt back in (e.g. to keep chaining
further); `hello-ccache` and every `nix-*` component always keep it —
`hello-ccache` because `--cache-file` needs a real declared output to
resolve, `nix-*` components because that's what makes per-target
caching work at all.
