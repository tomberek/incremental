# nixgg

A `gg`-style build accelerator using **Nix CA derivations as the thunks**.

Every `-c` compile, `ar` archive, and link invocation is intercepted by
a shim, turned into a content-addressed derivation, and built via
`nix build`. Object files, static libraries, and binaries live in
`/nix/store` (or a private alt store) keyed by *the contents of the
inputs + the compiler + flags*, so identical input always yields the
same output path and rebuilds are free.

Zero Python. Bash + awk + jq + make + nix, one Python-free pinned
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

Real project:

```sh
NIXGG_MODE=placeholder ./nixgg/mosh.sh          # clone + build mosh
/tmp/nixgg-mosh/mosh/src/frontend/mosh-client --version
```

## Layout

- `flake.nix` / `flake.lock` — pinned nixpkgs (nixos-unstable); the
  sole source of the toolchain (`gcc`, `bash`, `coreutils`, the `nix`
  CLI itself) and the mosh build environment.
- `builder.nix` / `linker.nix` / `archiver.nix` — CA derivations for
  compile, link, and archive.
- `nixgg` — single-command wrapper CLI: `run`, `eval`, `force`,
  `build`, `stats`, `env`. Auto-bootstraps env vars on first use.
- `bootstrap.sh` — sourced by `nixgg` to populate `NIXGG_*` from
  `.#env-shell` + alt-store copy.
- `lib.sh` — shared driver helpers (log, thunk_id, resolve_sidecar,
  wrapper_env_json, inputs_nix_from_json, nix_build_expr,
  emit_derivation, …).
- `shims/{cc,gcc,c++,g++,ar,ranlib}` — one-liners that dispatch to
  compile / link / ar drivers depending on argv.
- `compile-driver.sh` — argv parsing, staging, `nix store add`,
  builder.nix invocation.
- `link-driver.sh` — resolves sidecars, linker.nix invocation.
- `ar-driver.sh` — same for archives.
- `scan-headers.sh` — awk-based `gcc -MM -MG` output parser + header
  stager; emits `<abs>\t<staged-rel>` + `PROJECT_ROOT=` +
  `STAGED_IFLAG=` + `STORE_IFLAG=` sidebands.
- `force-make.sh` — the deferred-mode scheduler: reads sidecars, walks
  the thunk graph, emits a Makefile with one rule per thunk, runs
  `make -j`. Two hidden subcommands (`_one`, `_copy`) supply the
  rule bodies.
- `mosh.sh` — real-world integration demo (autoconf + protoc + mosh).

## Activity log

Set `NIXGG_LOG=/some/path.ndjson` before invoking any nixgg build.
Every compile / link / archive shim invocation appends one line
containing tool, source, output, resulting store path, wall-clock time,
and a cache-hit heuristic. Summarise with `nixgg stats <log>`;
`--since <epoch>` scopes to a time window.

## Realise vs. placeholder mode

- **`realise`** (default): every shim invocation immediately spawns
  `nix build`, blocking until the output is in the store. Always
  correct, but per-shim Nix startup dominates for large graphs.
- **`placeholder`**: shims record the intended derivation as a
  **thunk** in `$NIXGG_THUNKS_DIR` (default `.nixgg/thunks/`) and drop
  a placeholder file + `THUNK:<id>` sidecar. `make` marches on;
  nothing is built. A final `nixgg force <target…>` walks the graph
  and does a SINGLE `nix build` per thunk, scheduled by `make -j`.
  Nix owns parallelism and any `builders =` remote fanout.

  **Autoconf-style probes are auto-detected**: any invocation whose
  source or output starts with `conftest` is forced to realise mode so
  feature detection still gets a real answer.

Both modes yield bit-identical CA-store output paths.

The `nixgg build` subcommand does eval + force in one shot:

```sh
nixgg build --target hello -- make -j2
```

## Toolchain pin

`flake.nix` pins nixpkgs (currently `nixos-unstable`) and exports:

- `packages.<system>.{gcc,bash,coreutils,nix}` — toolchain components.
- `packages.<system>.env-shell` — a bash-sourceable file of
  `export NIXGG_… = /nix/store/…` lines. This is what `bootstrap.sh`
  builds and sources.
- `packages.<system>.toolchain-json` — same info as JSON.
- `packages.<system>.mosh-env` — autotools + libs closure for mosh;
  used via `nix develop .#mosh-env`.

Refresh with: `cd nixgg && nix flake update`.
