{
  lib,
  system,
  mkIncrementalNixComponents,
}:
let
  nixComponentNames = [
    "nix-util"
    "nix-util-c"
    "nix-store"
    "nix-store-c"
    "nix-fetchers"
    "nix-fetchers-c"
    "nix-expr"
    "nix-expr-c"
    "nix-flake"
    "nix-flake-c"
    "nix-main"
    "nix-main-c"
    "nix-cmd"
  ];
in
{
  nix-incremental =
    (mkIncrementalNixComponents {
      inherit system;
      target = "nix-cli";
    }).nix-cli;
}
// lib.genAttrs nixComponentNames (
  target: (mkIncrementalNixComponents { inherit system target; }).${target}
)
