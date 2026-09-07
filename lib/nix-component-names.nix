# Every NixOS/nix Meson component built as its own top-level target
# (as opposed to a dependency of nix-cli/nix-incremental) gets real
# cross-build ccache caching — see mk-incremental-nix-components.nix.
# Single source of truth so pkgs/nix-components.nix and the
# nix-components app stay in sync.
[
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
]
