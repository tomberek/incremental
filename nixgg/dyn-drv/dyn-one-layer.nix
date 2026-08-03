# One-layer dynamic derivation, following the upstream
# text-hashed-output.nix fixture.
#
# Three derivations at play:
#
#   inner   — a normal derivation. Its .drv exists at eval time; its
#             output is NOT built by the outer build. (Its build graph
#             is what dyn-drv "discovers" at outer-build time.)
#
#   producingDrv — a derivation whose *output* is the inner's .drv
#                  file. Marked outputHashMode="text" and name ending
#                  in ".drv". Its build just copies inner.drvPath.
#                  This is the "produce a drv" step.
#
#   wrapper — a regular derivation that consumes the dynamic drv via
#             `builtins.outputOf producingDrv.outPath "out"` — a
#             reference that Nix resolves by reading the .drv from
#             producingDrv's output and building THAT.
#
# What "dynamic" means here: at eval time we know producingDrv's
# hash but not what .drv bytes it will produce. `outputOf` gives us
# a placeholder that nix resolves after producingDrv is built.
#
# The upstream fixture doesn't use builder-rpc-v0. We follow suit —
# builder-rpc-v0 is orthogonal (path-of-output negotiation) and adds
# complexity we don't need for this test.
{
  pkgs ? import <nixpkgs> { },
}:
let
  cfg = import ./config.nix { inherit pkgs; };

  # Inner: normal derivation. Just a leaf.
  inner = derivation {
    name = "leaf";
    system = builtins.currentSystem;
    builder = cfg.shell;
    args = [
      "-c"
      "echo hi from leaf > $out"
    ];
  };

  # Producer: emits the inner .drv file as its output.
  # Name MUST end in ".drv" — Nix enforces this for drv-producing
  # outputs. outputHashMode "text" tells Nix the output IS a drv
  # file, not a directory tree.
  #
  # unsafeDiscardOutputDependency: without this, `inner.drvPath`
  # carries a "must-build inner" context that would force nix to
  # realise inner *before* running producingDrv — defeating the
  # whole point (dyn-drv means we don't know the .drv until the
  # outer build runs).
  producingDrv =
    let pn = builtins.currentTime; # silence unused
    in derivation {
      name = "leaf.drv";
      system = builtins.currentSystem;
      builder = cfg.shell;
      PATH = cfg.path;
      args = [
        "-c"
        "cp ${builtins.unsafeDiscardOutputDependency inner.drvPath} $out"
      ];
      __contentAddressed = true;
      outputHashMode = "text";
      outputHashAlgo = "sha256";
    };
in
{
  inherit inner producingDrv;

  # Consumer: outputOf takes producingDrv's outPath (which will BE
  # a .drv file, once built) and requests its "out". At build time
  # Nix does: build producingDrv → read the resulting .drv → build
  # THAT drv → return its output.
  wrapper = derivation {
    name = "wrapper";
    system = builtins.currentSystem;
    builder = cfg.shell;
    PATH = cfg.path;
    args = [
      "-c"
      ''
        cat ${builtins.outputOf producingDrv.outPath "out"} > $out
      ''
    ];
  };
}
