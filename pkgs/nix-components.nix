{
  lib,
  pkgs,
  system,
  mkIncrementalNixComponents,
}:
let
  nixComponentNames = import ../lib/nix-component-names.nix;
  components = lib.genAttrs nixComponentNames (
    target: (mkIncrementalNixComponents { inherit system target; }).${target}
  );
in
{
  nix-incremental =
    (mkIncrementalNixComponents {
      inherit system;
      target = "nix-cli";
    }).nix-cli;
  # All Meson components as one target — each built as its own
  # top-level installable (not a nix-cli dependency), so each keeps
  # its own cache-varying restore script and reports real ccache
  # hits under a single --override-input cache. See README,
  # "NixOS/nix itself".
  nix-all-components = pkgs.symlinkJoin {
    name = "nix-all-components";
    paths = builtins.attrValues components;
  };
}
// components
