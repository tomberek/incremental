# mkNixggBuild — wrap a user build command in a builder-rpc-v0
# derivation whose output is a *derivation file* (.drv). The
# consumer picks up the compiled artifact via
# `builtins.outputOf drv.outPath "out"`.
#
# Under the hood: the sandbox runs the user command with our shims on
# PATH. Each shim invocation (compile, archive, link) uploads a JSON
# derivation description via `nix derivation add` and symlinks the
# caller-visible output at the returned .drv path. The link shim
# additionally calls `nix store submit-output <linkDrv> out` for the
# target the user named. Nix resolves the chain when someone builds
# `mkNixggBuild.result`.
#
# See nixgg/dyn-drv/NOTES.md for the mechanism it's built on.
{
  lib,
  coreutils,
  gnumake,
  bash,
  gcc,
  nixgg,        # store path with bin/nixgg + shims/
  nixHelpers,   # nixgg-nix helper package (unused in sandbox mode, but
                # kept so tests can run non-sandbox against the same builder)
  patchedNix,   # nix with builder-rpc-v0 + submit-output
}:

{
  pname,
  version ? "0",
  src,
  # The command that produces the final artifact. Executed in a
  # subshell after all env is set up. `NIXGG_SANDBOX_TARGET` picks
  # which link becomes the outer derivation's output.
  buildCommand,
  # Path (relative or absolute) of the final artifact the user's
  # buildCommand produces. The link shim matches on this basename to
  # decide when to call submit-output.
  target,
  # Extra store paths the user's command needs at build time —
  # `pkg-config`, `perl`, whatever. Passed as inputs.srcs on the
  # outer drv.
  extraToolchain ? [ ],
}:

let
  # The outer derivation's name must equal the .drv basename the link
  # shim submits — Nix enforces submit-output's path-name matches
  # outputPathName(outerName, "out"). Our link shim names drvs
  # "bin-<target>.drv", so the outer must be named the same.
  #
  # Downside: multiple mkNixggBuild calls with the same target
  # basename will collide. Consumers must pass distinct targets.
  name = "bin-${baseNameOf target}.drv";

  drv = derivation {
  inherit name;
  system = builtins.currentSystem;
  builder = "${bash}/bin/bash";

  # Every store path the outer builder + our shims + user command
  # touch must be reachable from the sandbox. Baking them into env
  # vars gives Nix the string context it needs to mount them.
  PATH = lib.concatStringsSep ":" (
    [
      "${nixgg}/bin"
      "${nixgg}/shims"
      "${patchedNix}/bin"
      "${gcc}/bin"
      "${coreutils}/bin"
      "${bash}/bin"
      "${gnumake}/bin"
    ]
    ++ builtins.map (p: "${p}/bin") extraToolchain
  );

  # NIXGG_* the shims read.
  NIXGG_ROOT          = "${nixgg}";
  NIXGG_COMPILER_ROOT = "${gcc}";
  NIXGG_BASH_ROOT     = "${bash}";
  NIXGG_COREUTILS_ROOT = "${coreutils}";
  NIXGG_GNUMAKE_ROOT  = "${gnumake}";
  NIXGG_REAL_CC       = "${gcc}/bin/g++";
  NIXGG_NIX           = "${patchedNix}/bin/nix";
  NIXGG_NIX_HELPERS   = "${nixHelpers}";
  # Sandbox daemon → use whatever $NIX_REMOTE points at (set by
  # builder-rpc-v0).
  NIXGG_STORE         = "auto";
  # Turn on sandbox emission in the shims.
  NIXGG_SANDBOX       = "1";
  # The link shim matches this against its -o output to decide when
  # to submit-output.
  NIXGG_SANDBOX_TARGET = target;

  # nix-command + ca + dyn-drv on the inner nix invocations
  # (`nix derivation add`, `nix store add`, `nix store submit-output`).
  NIX_CONFIG = ''
    extra-experimental-features = nix-command ca-derivations dynamic-derivations
  '';

  requiredSystemFeatures = [ "builder-rpc-v0" ];

  __contentAddressed = true;
  outputHashMode = "text";
  outputHashAlgo = "sha256";

  args = [
    "-c"
    ''
      set -euo pipefail
      # Inside builder-rpc-v0, $out is intentionally unset. Anything
      # that stringifies it will fail; be paranoid.
      if [[ -n "''${out+set}" ]]; then
        echo "mkNixggBuild: expected \$out unset in builder-rpc-v0" >&2
        exit 1
      fi

      # Stage the source into a working dir. `src` is added to
      # inputs.srcs by string-context — see PATH above; we cp it
      # locally so the user's command can modify build artifacts
      # (make writes .o files next to sources).
      cp -r ${src} work
      chmod -R u+w work
      cd work

      # Run the user command. Shims fire, submit drvs, symlink outputs.
      # The link shim submits when it sees an -o matching
      # NIXGG_SANDBOX_TARGET.
      ${buildCommand}
    ''
  ];

  # Bring src's store path into the sandbox as an input.
  inherit src;
  };
in
{
  inherit drv;
  # Consumer entrypoint: `nix build … .result` walks the dyn-drv chain
  # and returns the final compiled artifact.
  result = builtins.outputOf drv.outPath "out";
}
