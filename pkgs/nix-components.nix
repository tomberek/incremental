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
      # scope.nix-cli's own pname is "nix" (not "nix-cli") — the
      # override callback in mkIncrementalNixComponents matches on
      # pname, so target has to be the real pname or nix-cli never
      # gets a cache-varying script at all (confirmed: it silently
      # fell into the "every dependency" branch with target =
      # "nix-cli", giving nix-incremental zero ccache incrementality).
      target = "nix";
      # name is the cache lookup/report key and defaults to target
      # ("nix") — but this flake exposes the package as
      # nix-incremental, so a real cache built by this same flake has
      # it under that name, not "nix". Without this, the restore
      # lookup (cache.packages.${system}.${name}.incremental) never
      # matches and silently falls back to "empty" every time,
      # regardless of --override-input cache (confirmed: 0/65 ccache
      # hits on a same-source rebuild until this was set).
      name = "nix-incremental";
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
