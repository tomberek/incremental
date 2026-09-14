# Incremental builds

Reuse outputs/caches from a previous build by overriding the `cache`
flake input to an earlier checkout (or a previous build, or any ref).
Point a tool's own cache dir/file at a restored `incremental` output
and let the tool decide what's still valid — this repo does the
restoring, not the deciding.

## Results

- **OpenCV** (`nixpkgs-opencv`, `pkgs.opencv4`, CMake): 99% real ccache
  hits on a same-source rebuild, full build **27m26s → 6m14s (~4.4x)** —
  the biggest absolute wall-clock win measured here for a C/C++/ccache
  package.
- **Kubernetes** (`nixpkgs-kubernetes`, `pkgs.kubernetes`, Go, 6
  `cmd/` components in one module): full build **14m43s → 4m17s
  (~3.4x)** on a same-source rebuild — the biggest Go package tried
  here, restoring `$GOCACHE` instead of ccache.
- **LLVM** (`nixpkgs-llvm`, `pkgs.llvmPackages.llvm`, CMake/Ninja,
  ~4200 translation units): 98% real ccache hits on a same-source
  rebuild, `buildPhase` itself **35m17s → 1m20s (~26x)**.
- **Real single-file patches, not just same-source reruns**: applying
  one small, real upstream commit to `nixpkgs-llvm`/`nixpkgs-opencv`
  and restoring from the *unpatched* build's cache still hits
  97.9%/98.9% — dropping by exactly the one file the patch touched,
  even at this scale. Same pattern confirmed on jq, redis, tmux,
  python3, perl, and (by wall-clock, not a hit-rate line — Go has no
  ccache-style report) kubernetes: a patch to one of its 6 components
  (`kubeadm`) rebuilds in about the same time as the same-source
  rebuild, confirming the other 5 weren't invalidated. A header-
  touching patch (fmt, protobuf) costs far more — 22-24% — a
  genuinely different, expected result, not a bug; see "Real nixpkgs
  packages" below.
- **A Haskell/GHC ecosystem that's safe by default**: unlike Cargo,
  GHC's recompilation-avoidance (via Cabal's own `previousIntermediates`
  mechanism) correctly detects real source changes under Nix's
  epoch-normalized mtimes with no workaround needed — confirmed on
  `pandoc-cli`, restoring a same-source cache skips recompiling every
  one of its own modules.
- **Found and fixed a real bug in NixOS/nix's own incremental build**:
  `nix-incremental` (the full `nix` CLI) silently never restored
  anything — two compounding key-mismatch bugs meant `--override-input
  cache` had zero effect on its derivation. Fixed; now 96% real hits
  (63/65) on a same-source rebuild. See "NixOS/nix itself" below.
- **ccache isn't universal** — confirmed, not assumed, for four real
  packages tried and dropped: `curl` (100% hits, 0 speedup — nothing
  to compile), `openssh` (0% hits — bakes `$out` into `-D` flags),
  `emacs` (1% hits — native-lisp `.eln` bypasses `$CC` via
  `libgccjit`), `gcc` (0/0 *invocations* — bootstraps its own compiler
  and never calls back through the ccache wrapper).

## Using this as a library from another flake

`inputs.cache`/`--override-input` requires the flake being built to
declare `cache` as an input — fine for packages that live in this
repo, but it means a third party has to edit their own `flake.nix` to
opt in. Every `mkIncremental`-based derivation instead carries
`passthru.withCache`, a plain function that takes a rev-pinned flake
ref and returns the same package restoring from that build — no
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
matching `nix build`'s own default:

```
$ nix run github:tomberek/incremental#with-cache -- . ".#default"
```

Baseline is auto-pinned to its locked rev via `nix flake metadata` if
it isn't already, so a plain local path or branch name works too:

```
$ nix run github:tomberek/incremental#with-cache -- \
    "git+file://$PWD?rev=<pre-edit-commit>" ".#default"
```

The target, by contrast, is built with `--impure` and can stay
unlocked/dirty — it's the thing actually being built, not looked up
inside `builtins.getFlake` for its own inputs. A bare name after `#`
expands to `packages.<current-system>.default`; use a full dotted path
(e.g. `checks.x86_64-linux.foo`) for anything else. The app is just
this, spelled without `--impure --expr`:

```
nix build --impure --expr \
  'let pkg = builtins.foldl'"'"' (acc: a: acc.${a})
       (builtins.getFlake "<target-flake-ref>") ["packages" "x86_64-linux" "default"];
   in pkg.withCache "<baseline-locked-flake-ref>"'
```

Every `mkIncremental`-based derivation also carries
`passthru.asCacheApp`: the same `withCache` call, but with the
baseline pre-filled to *this build's own already-fetched source*
(`inputs.self`, pinned via its own content hash — works even from a
dirty tree). Useful when there's no flake ref to type out at all:

```
nix run <this-flake>#default.passthru.asCacheApp -- <target-flake-ref>#<name-or-attrpath>
```

(Has to be a plain derivation, not `{ type = "app"; ... }` — `nix run`
only recognizes that shape under `apps.<system>.<name>`, not at an
arbitrary attrpath; `writeShellApplication`'s `meta.mainProgram` makes
a plain derivation work anywhere instead.)

`mkIncrementalGoPackage`, `mkIncrementalZigPackage`, `mkIncrementalSwiftPackage`, and
`mkIncrementalRustPackage` bake in the right `cacheVars`/`phase` for
those ecosystems (see "Examples in this repo" for why each needs what
it needs). `mkIncrementalHaskellPackage` is different — it doesn't use
`mkIncremental` at all, since nixpkgs' own Haskell builder already has
a first-class incremental mechanism (`previousIntermediates`); it just
turns that on and wires up `withCache`/`asCacheApp`, same shape as
everything else. `mkIncrementalCcachePackage` does the same for
ccache — one call site handles `ccacheEnv`'s setup/report shell and
`passthru.withCache`; pass `autotools = true` to also layer on
autoconf's `--cache-file`. For anything else, compose
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
to the restored dir instead of exporting an env var. More importantly,
Cargo's fingerprinting is mtime-based and Nix normalizes every
unpacked file's mtime to the epoch — a restored `target/` would look
"fresh" regardless of what actually changed. The fix is Cargo's
`-Zchecksum-freshness` (unlocked on stable via `RUSTC_BOOTSTRAP=1`),
switching it to content-hash staleness — the same fix ccache needed,
for the same reason. `rust-staleness-self-test` (see
`checks/README.md`) is what would catch a regression here: it
restores a cache built from *different* source and asserts the binary
isn't served stale.

### Haskell (`.#haskell`, `pkgs.haskellPackages.pandoc-cli`)

```
$ nix build .#haskell
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#haskell
```

Unlike every other ecosystem here, this one needed no restore script
or staleness fix at all: nixpkgs' own Haskell builder already has a
first-class incremental mechanism — pass `previousIntermediates` (a
prior build's `intermediates` output) and it splices
`dist/build` back in during `buildPhase`, before Cabal/GHC's own
recompilation-avoidance decides what's stale. That check is content-
and mtime-based like Cargo's, but — confirmed empirically, not
assumed — correctly detects real changes under Nix's epoch-normalized
mtimes, unlike Cargo. `mkIncrementalHaskellPackage` just turns the
mechanism on via `haskell.lib.compose.overrideCabal` (the *only* layer
that works — `doInstallIntermediates`/`enableSeparateIntermediatesOutput`
are constructor args to `mkDerivation`, computed once inside
nixpkgs' own builder before the final attrset exists, so a plain
`.overrideAttrs` silently produces no `intermediates` output at all).
Restoring a same-source cache skips compiling every one of pandoc's
own modules — only the final relink runs.

### ccache (hello-ccache, c)

```
$ nix build .#hello-ccache
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#hello-ccache
```

`mkIncrementalCcachePackage` is the one-call-site way to add ccache to
a C/C++ package — `c/` is the minimal worked example (no build
system, just `$CC` calls); `hello-ccache` is the `autotools = true`
worked example, which also caches autoconf's check results via
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
swapping `stdenv` after construction doesn't work on a plain
`stdenv.mkDerivation` result, and an eval-time assert catches this).
`phase` must be a hook that still runs given whatever the package
skips (`postPatch` always does; `preConfigure` doesn't if
`dontConfigure = true`). `nuke` (nuke real store-path references out
of ccache's own manifest before it lands in `incremental`) defaults
to `false` — fine for a build this small, but the real nixpkgs
examples below pass `nuke = true` explicitly once a build is big
enough to pick up real references (see `pkgs/nixpkgs-examples.nix`).

### Real nixpkgs packages

The above are toy examples; these check viability on something real —
every number below is a measured same-source cold→warm rebuild, not
an estimate:

| package | mechanism | hit rate | speedup |
|---|---|---|---|
| `nixpkgs-jq` | autotools + ccache | 95% | 38s → 22s (~1.7x) |
| `nixpkgs-redis` | ccache only (no `./configure`) | 96% | 4m46s → 42s (~6.8x) |
| `nixpkgs-tmux` | autotools + ccache | 100% | 2m → 1m13s (~1.6x) |
| `nixpkgs-python3` | ccache only, debug logging disabled | 99% | 4m16s → 3m24s (~1.2x) |
| `nixpkgs-perl` | ccache only (`Configure`, not autoconf) | 99% | 2m57s → 1m48s (~1.6x) |
| `nixpkgs-llvm` | ccache only (CMake/Ninja) | 98% | buildPhase 35m17s → 1m20s (~26x); overall 10816s → 2377s (~4.5x) |
| `nixpkgs-fmt` | ccache only (CMake) | 98% | ~87s → ~12s (~7x) |
| `nixpkgs-protobuf` | ccache only (CMake) | — | buildPhase ~6m cold; `doCheck` disabled (own test suite alone runs 15m+) |
| `nixpkgs-opencv` | ccache only (CMake) | 99% | 27m26s → 6m14s (~4.4x) |
| `nixpkgs-kubernetes` | `mkIncrementalGoPackage` (`$GOCACHE`, no ccache) | — | 14m43s → 4m17s (~3.4x) |

```
$ nix build .#nixpkgs-jq
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-jq
```

(same for `nixpkgs-redis`/`nixpkgs-tmux`/`nixpkgs-python3`/
`nixpkgs-perl`/`nixpkgs-llvm`/`nixpkgs-fmt`/`nixpkgs-protobuf`/
`nixpkgs-opencv`/`nixpkgs-kubernetes`; `nixpkgs-llvm`,
`nixpkgs-opencv`, and `nixpkgs-kubernetes` aren't in CI — cold builds
take 35+, ~27, and ~15 minutes respectively on 22 local cores.
`nixpkgs-kubernetes` also has no hit-rate column above — it's
`mkIncrementalGoPackage` restoring `$GOCACHE`, the same mechanism as
the toy `.#golang` example, not ccache, so there's no per-file hit
count to report; only wall-clock is measured.)

`tmux` hits 100% but only gets ~1.6x, and `llvm`'s `buildPhase` speedup
(~26x) doesn't carry through to its overall wall-clock (~4.5x) —
`checkPhase` runs LLVM's own `lit` test suite every build regardless
of caching (432–550s ccache never touches). **100% cache hits doesn't
mean proportionally faster** — it means whatever ccache *can* see was
fully reused; how much of the wall-clock that actually is depends on
the package. `python3` hits the same pattern for a different reason:
`postInstall` runs `python -m compileall` over the entire stdlib three
times, pure bytecode compilation ccache never sees.

`redis`/`perl`/`llvm`/`fmt`/`protobuf`/`opencv` are ccache-only (no
`--cache-file`) because none has a real autoconf `./configure`: redis
is a plain Makefile, perl's own `Configure` isn't autoconf, llvm/fmt/
protobuf/opencv are CMake. `python3` *does*
have a real `./configure`, but its nixpkgs derivation restricts
`outputChecks.out` from referencing `openssl-dev`; a composed
`incremental` output inherits that same restriction, and
`--with-openssl=<path>-dev` in `configureFlags` means `config.cache`
would legitimately record that path, tripping the check. Dropping
`--cache-file` avoids that — but at python3's scale, `ccacheEnv`'s own
`CCACHE_DEBUG=1` debug logs leaked the same disallowed path through a
different route (hundreds of autoconf `conftest` probes, each logging
its full compile command line); disabling debug logging for this one
package sidesteps needing to scrub those files at all.

**Proving incrementality under a real code change, not just a
same-source rerun:** every `nixpkgs-*-patched` variant applies one
small, real upstream commit (see `patches/`) on top of the unpatched
package, sharing its cache key. Restoring from the *unpatched* build's
cache and building the *patched* one only recompiles what the patch
touched — confirmed at every scale tested, down to the exact file
count:

```
$ nix build .#nixpkgs-jq
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#nixpkgs-jq-patched
```

| patched package | patch | hits | vs. unpatched |
|---|---|---|---|
| `nixpkgs-jq-patched` | one line, `src/main.c` | 23/24 (95%) | same 95% |
| `nixpkgs-llvm-patched` | one function, `MemoryDependenceAnalysis.cpp` | 4075/4159 (97.9%) | 98.0% unpatched, ~4200 TUs |
| `nixpkgs-fmt-patched` | header fix, `include/fmt/format.h` | 13/54 (24%) | 98% unpatched — every `.cc` includes the header |
| `nixpkgs-protobuf-patched` | leaf `.cc` + its header, `repeated_field.{cc,h}` | 80/360 (22%) | — same "widely-included header" cost, at 10x the scale |
| `nixpkgs-opencv-patched` | one line, `connectedcomponents.cpp` | 1855/1875 (98.9%) | 99.0% unpatched — a narrow leaf fix, not a header |
| `nixpkgs-kubernetes-patched` | one leaf file, `cmd/kubeadm/.../config.go` | — (Go, no hits) | 4m49s vs. 4m17s same-source — the other 5 built components weren't invalidated |

A header change costs proportionally more than a leaf-file one — not
a bug, the same tradeoff any C/C++ build (cached or not) makes:
`fmt`/`protobuf`'s patches touch a header every translation unit
includes, so most of the build recompiles regardless of caching,
while `jq`/`llvm`/`opencv`'s patches touch one file only their own
translation unit depends on.

Not every C package benefits — tried and dropped, each confirmed by
measurement, not guessed from reading the build:

- **`curl`**: 100% ccache hits, 0% real speedup — build time is
  man-page rendering, not compilation.
- **`openssh`**: 0% hits — bakes its own `$out` into `-D` flags
  (`-D_PATH_SSH_PROGRAM=...`), so every compile command differs
  between builds regardless of source changes.
- **`nginx`**: incompatible outright — its `./configure` isn't
  autoconf and rejects `--cache-file`.
- **`emacs`**: 1% hits (3/155) — native-lisp `.eln` compiles through
  `libgccjit` in-process during Emacs's own "dump" step, never through
  `$CC`. A real structural blind spot for a compiler-wrapping cache,
  not a bug here.
- **`gcc`**: 0/0 ccache *invocations* — the same blind spot as emacs,
  just compiling itself instead of Lisp. GCC bootstraps its own
  compiler (`xgcc`) once with the host `$CC`, then uses that
  self-built `xgcc` — never the ccache wrapper — for the ~2500
  compiles that make up the rest of the build. Warm was *slower* than
  cold (932s vs. 732s): ccache overhead with zero payoff.

### NixOS/nix itself (nix-incremental)

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

`nix-incremental` builds the full CLI the same way — and until
recently, silently didn't. Two compounding bugs: the override matched
on the component's own Meson `pname`, but `nix-cli`'s real `pname` is
`"nix"`, not `"nix-cli"` — the match failed, and the *cache lookup*
used the same wrong string as its key, so it silently restored from
`"empty"` every time regardless of `--override-input cache`. No error,
no warning — just a derivation that never changed shape whether or
not the override was passed. Confirmed via `nix eval`: the
`.incremental` output path was byte-identical with and without the
override, before the fix. Fixed by separating `target` (matches the
real `pname`) from `name` (the cache lookup/report key, defaults to
`target` but overridable) — `nix-incremental` now hits **96% (63/65)**
on a same-source rebuild.

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

Content-addressed caches are safe to restore this way: ccache keys on
preprocessed source + flags, Go/Zig's build caches similarly,
autoconf's `config.cache` stores check results with no path baked in.
Cargo's isn't (mtime-based) — see Rust above.

Caching `./configure`'s actual *output* — `config.status`, the
generated `Makefile`, `config.h` — isn't safe and isn't done here.
Autotools bakes the configure-time prefix into those as text (and for
gettext-style builds, directly into the compiled binary via
`-DLOCALEDIR=...`); restoring a cached `Makefile` against a new `$out`
breaks the install or ships a binary pointing at a stale store path.
Tried and dropped: byte-preserving find/replace on a placeholder
prefix (breaks LTO sections and libtool symlinks; also loses Make's
own mtime-based staleness check since Nix normalizes source mtimes),
and caching only autoreconf's output (misses `m4_esyscmd`-derived
version strings like gnulib's `git-version-gen`). For compile-level
caching beyond `config.cache`, use `ccacheStdenv` instead of trying to
skip `./configure`.

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
