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

rm -f ./*.o ./*.o.nixgg hello hello.nixgg
../nixgg run -- make -j2                        # warm: all cache hits

sed -i 's/greeting()/greeting() /' main.cc      # semantic edit
rm -f ./*.o ./*.o.nixgg hello hello.nixgg
../nixgg run -- make -j2                        # only main.o + link redo
git checkout main.cc                            # restore
```

Real project (mosh — autoconf + protoc + libs):

```sh
NIXGG_MODE=placeholder ./nixgg/mosh.sh          # clone + build
/tmp/nixgg-mosh/mosh/src/frontend/mosh-client --version
```

## Layout

- `flake.nix` / `flake.lock` — pinned nixpkgs (nixos-unstable); the
  sole source of the toolchain (`gcc`, `bash`, `coreutils`, the `nix`
  CLI itself), the `nix/` helpers, and the mosh build environment.
- `nix/` — the Nix helper files, realised into the store as one
  package (`nixgg-nix`) so drivers can `import` them by store-path
  under pure eval.
    - `builder.nix` — per-TU CA compile derivation.
    - `linker.nix` — CA link derivation.
    - `archiver.nix` — CA `ar` derivation.
    - `pure-store-path.nix` — pure-eval-compatible replacement for
      `builtins.storePath` via `unsafeDiscardStringContext` +
      `appendContext`. Lets every driver work without `--impure`.
- `nixgg` — single-command CLI: `run`, `eval`, `force`, `build`,
  `stats`, `env`. Auto-bootstraps env vars on first use; sources
  `.#env-shell` from the flake to populate `NIXGG_*`.
- `lib.sh` — shared driver helpers (log, thunk_id, resolve_sidecar,
  wrapper_env_json, inputs_nix_from_json, nix_build_expr,
  emit_derivation, …).
- `shims/{cc,gcc,c++,g++,ar,ranlib}` — one-liners that dispatch to
  compile / link / ar drivers depending on argv.
- `compile-driver.sh` — argv parsing, staging, `nix store add`,
  invokes `nix/builder.nix`.
- `link-driver.sh` — resolves sidecars, invokes `nix/linker.nix`.
- `ar-driver.sh` — same for archives.
- `scan-headers.sh` — awk-based `gcc -MM -MG` output parser + header
  stager; emits `<abs>\t<staged-rel>` + `PROJECT_ROOT=` +
  `STAGED_IFLAG=` + `STORE_IFLAG=` sidebands.
- `mosh.sh` — real-world integration demo.

## Realise vs. placeholder mode

Selected by `NIXGG_MODE` (default: `realise`) or the `nixgg` subcommand.

- **`realise`** — every shim invocation immediately spawns `nix build`,
  blocking until the output is in the store. Simple, always correct;
  per-shim Nix startup dominates for large graphs.
- **`placeholder`** — shims write a **`.nix` thunk file** to
  `$NIXGG_THUNKS_DIR` (default `.nixgg/thunks/<id>.nix`) and drop a
  placeholder file + `NIX:<abs-path>.nix` sidecar at the output.
  Each thunk is a self-contained `import <helper>.nix { … }` expression
  that references its inputs via `import <other-thunk>.nix` or
  `pureStorePath "/nix/store/…"`. `make` sees a file and marches on.

  A final `nixgg force <target…>` reads each target's sidecar and runs
  `nix build --file <thunk>.nix`. Nix's own evaluator walks the
  transitive `import` graph and schedules with its usual `-j`.

  **Autoconf conftests auto-fall-back to realise mode**: any invocation
  whose source or output starts with `conftest` runs synchronously so
  configure sees real results.

Both modes produce bit-identical CA-store output paths.

The `nixgg build` subcommand does eval + force in one shot:

```sh
nixgg build --target hello -- make -j2
```

## Activity log

Set `NIXGG_LOG=/some/path.ndjson` before invoking any nixgg build. Every
compile / link / archive shim invocation appends one line containing
tool, source, output, resulting store path, wall-clock time, and a
cache-hit heuristic. Summarise with `nixgg stats <log>`; `--since
<epoch>` scopes to a time window.

## Toolchain pin

`flake.nix` pins nixpkgs (currently `nixos-unstable`) and exports:

- `packages.<system>.{gcc,bash,coreutils,nix}` — toolchain components.
- `packages.<system>.nixgg-nix` — `./nix` copied into the store, so
  drivers can `import` it under pure eval.
- `packages.<system>.env-shell` — a bash-sourceable file of
  `export NIXGG_… = /nix/store/…` lines. This is what `nixgg` builds
  and sources during bootstrap.
- `packages.<system>.toolchain-json` — same info as JSON.
- `packages.<system>.mosh-env` — autotools + libs closure for mosh;
  used via `nix develop .#mosh-env`.

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
