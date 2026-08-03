# Emit a dynamic derivation via `nix derivation add` (JSON on stdin)
# from inside a builder-rpc-v0 sandbox, then submit its .drv as the
# outer derivation's output. Consumer chains via `builtins.outputOf`.
#
# This is the pattern nix-ninja / sandstone use (nix-ninja does it
# via the raw daemon RPC in Rust; sandstone via `nix derivation add`
# shell-out under recursive-nix; upstream ships this via
# builder-rpc-v0 CLI wrappers). We take the shell-out path — same
# effect, no wire-protocol work in Go.
#
# Adapted from
# NixOS/nix::tests/functional/dyn-drv/non-trivial-submitted.nix,
# simplified to one inner drv.
{
  pkgs ? import <nixpkgs> { },
  patchedNix,
}:
let
  cfg = import ./config.nix { inherit pkgs; };

  outer = derivation {
    name = "leaf.drv";
    system = builtins.currentSystem;
    builder = cfg.shell;
    PATH = "${patchedNix}/bin:${cfg.path}";

    requiredSystemFeatures = [ "builder-rpc-v0" ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";

    args = [
      "-c"
      ''
        set -euo pipefail
        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

        # Compute the "out" placeholder Nix will expect inside this
        # derivation's env at build time. The inner drv references
        # its own $out via this placeholder.
        placeholder=$(nix eval --raw --expr 'builtins.placeholder "out"')

        # Build the JSON derivation description directly. `nix
        # derivation add` reads it on stdin, inserts a .drv into
        # the store, prints the store path.
        # Every store path the inner drv references must be listed
        # in inputs.srcs — Nix uses this to know what to mount in the
        # inner build's sandbox. Format is basename (hash + name), no
        # `/nix/store/` prefix; `nix derivation add` rejects full
        # paths as "illegal base-32 character '/'".
        json=$(cat <<EOF
        {
          "name": "leaf",
          "system": "${builtins.currentSystem}",
          "builder": "${cfg.shell}",
          "args": ["-c", "echo hi from inner leaf > \$out"],
          "env": {
            "out": "$placeholder",
            "PATH": ${builtins.toJSON cfg.path}
          },
          "inputs": {
            "drvs": {},
            "srcs": ${builtins.toJSON (map (p: baseNameOf "${p}") [
              pkgs.bash
              pkgs.coreutils
            ])}
          },
          "outputs": {
            "out": { "method": "nar", "hashAlgo": "sha256" }
          },
          "version": 4
        }
        EOF
        )
        drvPath=$(echo "$json" | nix derivation add)
        echo "inner drv: $drvPath" >&2

        # Submit that .drv as our own output.
        nix store submit-output "$drvPath" out
      ''
    ];
  };
in
{
  inherit outer;
  # Consumer: outputOf resolves outer → its inner .drv → the leaf.
  leafOut = builtins.outputOf outer.outPath "out";
}
