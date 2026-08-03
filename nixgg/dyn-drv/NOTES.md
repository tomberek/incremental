# Dynamic derivations — what we learned

Scratch space for the sandbox-emit-drv pattern. Each `.nix` file here
is a working experiment against the patched Nix from PR
[NixOS/nix#15793][pr]. Together they map the primitives we'll use to
run nixgg builds inside a Nix sandbox.

[pr]: https://github.com/NixOS/nix/pull/15793

## The three primitives

`patched-nix` exposes three primitives that combine to give us
"produce a derivation as this derivation's output" — the whole point
of dynamic derivations:

1. **`outputHashMode = "text"`** + name ending in `.drv` — declares
   that this derivation's output *is* a `.drv` file. The bytes at
   `$out` are a serialized derivation.
2. **`nix derivation add`** (CLI, reads JSON on stdin, prints the
   resulting `.drv` store path). Works inside a `builder-rpc-v0`
   sandbox — the restricted RPC allowlist includes it.
3. **`nix store submit-output <drv-path> <output-name>`** — registers
   a store path as the currently-running derivation's named output.
   `$out` is NOT set inside a `builder-rpc-v0` builder; you submit
   instead.

Downstream, `builtins.outputOf outerDrv.outPath "out"` gives the
consumer a placeholder for whatever the emitted `.drv` will produce.
Nix chains the resolution: build outer → read its output (a `.drv`)
→ build that drv → substitute the placeholder.

## Files

- **`config.nix`** — small helper mirroring the upstream test
  fixture. Wraps `builtins.derivation` with a `bash + coreutils` PATH
  so we can write `buildCommand`-style scripts.
- **`dyn-one-layer.nix`** — smallest possible dyn-drv chain. Three
  derivations: a leaf, a producer whose *output* is the leaf's `.drv`,
  and a wrapper that consumes via `outputOf`. **No sandbox, no
  builder-rpc.** Follows the upstream `text-hashed-output.nix`
  fixture. Proves the plain `outputOf` resolution mechanism works.
- **`dyn-json-drv.nix`** — the target pattern. A single outer
  derivation with `requiredSystemFeatures = [ "builder-rpc-v0" ]`;
  its builder constructs a JSON derivation description, pipes it to
  `nix derivation add`, and `nix store submit-output`s the resulting
  `.drv`. This is what nixgg's outer wrapper will look like.
- **`nixgg-sandbox.nix`** — an early experiment (superseded, kept for
  reference). Tried to run `nix-instantiate` inside the sandbox on
  our existing `.nix`-file thunks. Doesn't work: the inner nix in a
  `builder-rpc-v0` sandbox has no `/nix/var/nix/db` view; it can't
  instantiate or resolve store paths. Only `nix derivation add` (and
  `nix store add`, `submit-output`) work through the RPC.

## Gotchas we hit

### `srcs` in JSON is a basename, not a path

```json
"inputs": {
  "drvs": {},
  "srcs": ["0641h8qfqaxnwrsw2nzrz6i1wbzyx92l-bash-interactive-5.3p9"]
}
```

Not `/nix/store/…-bash-…`. Passing the full path gives
`store path '…' contains illegal base-32 character '/'`. Docs don't
mention this — we discovered it by feeding examples in.

### The `$out` placeholder is per-derivation

Every derivation has a placeholder `$out` that Nix substitutes at
build time. We generate ours with:

```bash
placeholder=$(nix eval --raw --expr 'builtins.placeholder "out"')
```

Then interpolate `$placeholder` into the emitted JSON's `env.out`
and reference `\$out` inside the args (escaped because it's inside a
here-doc).

### Name must end in `.drv` for text-mode

A derivation with `outputHashMode = "text"` whose name doesn't end in
`.drv` fails eval with: "derivation names are allowed to end in
`.drv` only if they produce a single derivation file". The check
runs at eval time, before the builder starts.

### `unsafeDiscardOutputDependency` on `.drvPath`

When passing a store-path input to the sandbox as an env var, use:

```nix
bash = "${builtins.unsafeDiscardOutputDependency pkgs.bash.drvPath}!out";
```

Without `unsafeDiscardOutputDependency`, the string carries a
`DrvDeep` context that forces the *inner* build to happen at outer
eval time, defeating the dynamic property. Sandstone uses this
pattern; upstream fixtures don't (they use FODs so the .drv is known
statically).

### `nix-instantiate` doesn't work inside `builder-rpc-v0`

We tried, hoping to reuse our existing `.nix` thunks unchanged.
Doesn't work: the inner nix inside a `builder-rpc-v0` sandbox has
no store database, tries to set up a chroot store at `/homeless-shelter`,
then tries to substitute inputs from `cache.nixos.org` (unreachable).
The RPC allowlist doesn't include the ops nix-instantiate needs.

So nixgg's sandboxed mode has to skip the `.nix`-thunk step entirely
and go straight to JSON drvs via `nix derivation add`.

## Reference: what nix-ninja and sandstone do

**nix-ninja** (Rust) has its own daemon-wire crate
(`nix-builder-rpc-client`). It speaks the raw Nix worker protocol
against `$NIX_REMOTE`, calling `AddCaToStore` with method `Text` to
upload the ATerm-serialized derivation. Uses `builder-rpc-v0`.

**sandstone** (Haskell) shells out to `nix derivation add` via
`readProcess`. Requires `recursive-nix` (broader socket) instead of
`builder-rpc-v0`.

We take a hybrid: shell out to `nix derivation add` like sandstone,
but stay on `builder-rpc-v0` like nix-ninja. Confirmed working via
`dyn-json-drv.nix`. No need to write ATerm bytes or Rust
wire-protocol code — the CLI handles both.

## What comes next

The nixgg shims already have all the information a JSON drv needs:
tool, source, headers, flags, output name, sibling inputs. Instead
of writing `.nix` thunks, they'd construct a JSON drv description
per invocation and hand it to `nix derivation add` (over the RPC
socket via the CLI). The link shim gathers everything, submits the
final drv, exits. The outer wrapper — mkNixggBuild — is a small
Nix function that sets `outputHashMode = "text"`, `.drv` suffix,
`requiredSystemFeatures`, and threads toolchain paths in.

See `TASKS.md` for the integration plan.
