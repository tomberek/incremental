# nixgg

A `gg`-style build accelerator using **Nix CA derivations as the thunks**.

Every `-c` compile, `ar` archive, and link invocation is intercepted by
a shim, turned into a content-addressed derivation, and built via
`nix build`. Object files, static libraries, and binaries live in
`/nix/store` (or a private alt store) keyed by *the contents of the
inputs + the compiler + flags*, so identical input always yields the
same output path and rebuilds are free.

Zero Python, no `--impure`. Bash + awk + jq + make + nix, one pinned
toolchain via `flake.nix`.

## Try it

No env setup required. `nixgg` self-bootstraps: on first run it builds
`.#env-shell` from the flake, resolves toolchain paths, and populates
the alt store at `/tmp/nixgg-store` (override with `ALT_STORE=…`).

Toy example — cold build, cache-hit rebuild, edit-and-rebuild:

```sh
cd nixgg/example

../nixgg run -- make -j2                        # cold: 2 compiles + 1 link
./hello

rm -f ./*.o hello
../nixgg run -- make -j2                        # warm: all cache hits

sed -i 's/greeting()/greeting() /' main.cc      # semantic edit
rm -f ./*.o hello
../nixgg run -- make -j2                        # only main.o + link redo
git checkout main.cc                            # restore
```

Real project (mosh — autoconf + protoc + libs):

```sh
NIXGG_MODE=placeholder ./nixgg/mosh.sh          # clone + build
/tmp/nixgg-mosh/mosh/src/frontend/mosh-client --version
```

## Every output is a symlink

nixgg never writes bytes to your build tree. Every artifact it produces
— `.o`, `.a`, `hello`, `mosh-client` — is a symlink:

- **Realised** — target symlinks into the store:
  `hello → /tmp/nixgg-store/nix/store/…-bin-hello/hello`
- **Placeholder** (deferred) — target symlinks to a thunk `.nix` file:
  `main.o → …/example/.nixgg/thunks/<id>.nix`

The shim classifies inputs by `readlink -f`. No sidecar files, no
metadata drift. `nix build --file <thunk>.nix` follows the transitive
`import` graph to realise the whole DAG.

## Layout

- `flake.nix` / `flake.lock` — pinned nixpkgs (nixos-unstable); the
  sole source of the toolchain (`gcc`, `bash`, `coreutils`, the `nix`
  CLI itself), the `nix/` helpers, and the mosh build environment.
- `nix/` — the Nix helper files, realised into the store as one package
  (`nixgg-nix`) so drivers can `import` them by store-path under pure
  eval.
    - `builder.nix` — per-TU CA compile derivation.
    - `linker.nix` — CA link derivation.
    - `archiver.nix` — CA `ar` derivation.
    - `pure-store-path.nix` — pure-eval-compatible replacement for
      `builtins.storePath` via `unsafeDiscardStringContext` +
      `appendContext`. Lets every driver work without `--impure`.
- `nixgg` — single-command CLI: `run`, `eval`, `force`, `build`, `emit`,
  `stats`, `env`. Auto-bootstraps env vars on first use.
- `lib.sh` — shared driver helpers (`log`, `thunk_id`, `write_thunk`,
  `link_placeholder`, `link_store_to_output`, `classify_target`,
  `wrapper_env_json`, `inputs_nix_from_json`, `nix_build_expr`,
  `emit_derivation`, …).
- `shims/{cc,gcc,c++,g++,ar,ranlib}` — one-liners that dispatch to
  compile / link / ar drivers depending on argv.
- `compile-driver.sh` — argv parsing, staging, `nix store add`,
  invokes `nix/builder.nix`.
- `link-driver.sh` — classifies input symlinks, invokes `nix/linker.nix`.
- `ar-driver.sh` — same for archives.
- `scan-headers.sh` — awk-based `gcc -MM -MG` output parser + header
  stager; emits `<abs>\t<staged-rel>` + `PROJECT_ROOT=` +
  `STAGED_IFLAG=` + `STORE_IFLAG=` sidebands.
- `mosh.sh` — real-world integration demo (autoconf + protoc + mosh).

## Realise vs. placeholder mode

Selected by `NIXGG_MODE` (default: `realise`) or the `nixgg` subcommand.

- **`realise`** — every shim invocation immediately spawns `nix build`
  and re-targets the output symlink at the resulting `/nix/store/…`
  path. Simple, always correct; per-shim Nix startup dominates for
  large graphs.
- **`placeholder`** — shims write a `.nix` thunk file to
  `$NIXGG_THUNKS_DIR` (default `.nixgg/thunks/<id>.nix`) and symlink the
  target at it. Each thunk is a self-contained
  `import <helper>.nix { … }` expression that references its inputs
  either via `import <other-thunk>.nix` (unrealised sibling) or
  `pureStorePath "/nix/store/…"` (already realised). `make` sees a file
  and marches on.

  A final `nixgg force <target…>` classifies the target, calls
  `nix build --file <thunk>.nix`, and re-points the target symlink at
  the resulting store path. Nix's own evaluator walks the transitive
  `import` graph and schedules with its usual `-j`.

  **Autoconf conftests auto-fall-back to realise mode**: any invocation
  whose source or output starts with `conftest` runs synchronously so
  configure sees real results.

Both modes produce bit-identical CA-store output paths.

The `nixgg build` subcommand does eval + force in one shot:

```sh
nixgg build --target hello -- make -j2
```

## `nixgg emit`: outer builder-rpc-v0 derivation

Given one or more targets currently pointing at thunks, `nixgg emit`
prints a self-contained Nix expression with two attributes:

- **`direct.<name>`** — imports the thunk graph directly. Same result
  as `nixgg force`. Works on any Nix.
- **`sandboxed.<name>`** — an outer content-addressed derivation with
  `requiredSystemFeatures = [ "builder-rpc-v0" ]`. Emit realises the
  target's thunk graph out-of-sandbox and passes the resulting store
  path as an input; the sandboxed builder then calls
  `nix store submit-output` (a new command in PR 15793) to register
  that path as its own `out`. This proves the daemon RPC path works
  end-to-end without needing to run the whole build inside the sandbox.

The `sandboxed` variant needs a Nix with **PR
[NixOS/nix#15793](https://github.com/NixOS/nix/pull/15793)** merged.
The flake pulls that build from `refs/pull/15793/head` and pins it in
`flake.lock`; `nixgg emit` auto-embeds its store path into the
generated `.nix` file. No manual `NIXGG_PATCHED_NIX=` needed.

Bring-your-own-clone workflow:

```sh
# 1. Run the build once to populate .nixgg/thunks/ with .nix files
#    and turn each output into a symlink to its thunk.
nixgg eval -- make -j2

# 2. Emit a self-contained expression for the target(s).
NIXGG_EMIT_OUT=inside-sandbox.nix nixgg emit hello

# 3. Get PR 15793's nix from the flake.
PATCHED=$(nix build /path/to/nixgg#patched-nix --no-link --print-out-paths)/bin/nix

# 4. Build the sandboxed variant.
NIX_CONFIG='experimental-features = nix-command flakes ca-derivations dynamic-derivations
extra-system-features = builder-rpc-v0
store = local?root=/tmp/nixgg-store
sandbox = false' \
  "$PATCHED" build --no-link --print-out-paths \
    --file inside-sandbox.nix sandboxed._0
```

The `direct.<name>` attribute in the same file works with mainline Nix
and needs none of the above ceremony:

```sh
nix build --file inside-sandbox.nix direct._0
```

## Activity log

Set `NIXGG_LOG=/some/path.ndjson` before invoking any nixgg build. Every
compile / link / archive shim invocation appends one line containing
tool, source, output, resulting store path, wall-clock time, and a
cache-hit heuristic. Summarise with `nixgg stats <log>`; `--since
<epoch>` scopes to a time window.

## Toolchain pin

`flake.nix` has two inputs, both pinned in `flake.lock`:

- `nixpkgs` — currently tracks `nixos-unstable`; source of gcc / bash /
  coreutils / stable nix / the mosh build environment.
- `nix-15793` — fetched from `refs/pull/15793/head` of NixOS/nix
  (`git+https://github.com/NixOS/nix.git?ref=refs/pull/15793/head`).
  Only used by `nixgg emit`'s sandboxed variant.

Exposed packages (all under `packages.<system>.<name>`):

- `gcc` / `bash` / `coreutils` / `nix` — toolchain components.
- `nixgg-nix` — `./nix` copied into the store, so drivers can `import`
  it under pure eval.
- `patched-nix` — the PR 15793 nix binary. Auto-embedded into
  `nixgg emit`'s `.sandboxed` output.
- `env-shell` — a bash-sourceable file of `export NIXGG_… =
  /nix/store/…` lines. This is what `nixgg` builds and sources during
  bootstrap.
- `toolchain-json` — same info as JSON.
- `mosh-env` — autotools + libs closure for mosh; used via
  `nix develop .#mosh-env`.

Refresh with: `cd nixgg && nix flake update`.

## Pure eval

Every `nix build` invocation runs under Nix's default pure-eval mode.
Two tricks make this work with our concrete-store-path-heavy design:

1. **`pureStorePath`** (in `nix/pure-store-path.nix`) — a pure-eval
   replacement for `builtins.storePath`. Takes a string like
   `/nix/store/…` and returns a string with store context attached, so
   Nix treats it as a proper reference. No filesystem read, no
   existence check — callers ensure paths are valid by construction
   (they come from `nix store add` / `nix build --print-out-paths`).
2. **Helpers in the store** — the `nix/` directory is realised as a
   `runCommand` in the flake (`packages.<system>.nixgg-nix`), so
   drivers can `import /nix/store/…-nixgg-nix/builder.nix { … }`. Pure
   eval allows imports from store paths but not from arbitrary absolute
   paths.

Realise-mode `nix build` writes its expression body to a temp `.nix`
file and uses `--file`, because `--expr` is treated as impure in newer
Nix. The `--file` path is pure-eval-compatible.
