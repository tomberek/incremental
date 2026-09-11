{
  inputs,
  pkgs,
  name,
}:

# The withCache override-and-recurse pattern, packaged as a
# `nix run`-able derivation that needs neither a flake ref for this
# package (baseline is this build's own already-fetched source,
# inputs.self, pinned via its own narHash so it works even on a
# dirty tree) nor edits to the target's flake.nix:
#   nix run <this-flake>#<name>.passthru.asCacheApp -- <target>
# Plain derivation, not `{ type = "app"; ... }` — nix run only
# recognizes that shape under apps.<system>.<name>, not at an
# arbitrary attrpath; a derivation with meta.mainProgram set (which
# writeShellApplication does) works at any attrpath instead.
#
# Re-resolves `pkg.withCache` at runtime via `builtins.getFlake`
# rather than closing over it — correct regardless of which
# mkIncremental*Package wrapper actually defines `withCache` on the
# target, so this only needs to exist once, here, and every wrapper
# inherits it unchanged from mkIncrementalPackage's passthru.
let
  # path: needs a narHash to be treated as locked; getFlake otherwise
  # refuses it same as an unpinned rev.
  encodedNarHash = pkgs.lib.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ] inputs.self.narHash;
  baselineRef = "path:${inputs.self.outPath}?narHash=${encodedNarHash}";
in
pkgs.writeShellApplication {
  name = "as-cache-app";
  runtimeInputs = [
    pkgs.nix
    pkgs.jq
  ];
  text = ''
    target=".#default"
    if [ "$#" -gt 0 ] && [[ "$1" == *#* ]]; then
      target="$1"
      shift
    fi

    flake_ref="''${target%%#*}"
    attr_path_str="''${target#*#}"

    case "$attr_path_str" in
    *.*) ;; # already a full attrpath, e.g. checks.x86_64-linux.foo
    *)
      system=$(nix eval --impure --raw --expr builtins.currentSystem)
      attr_path_str="packages.$system.$attr_path_str"
      ;;
    esac

    flake_ref="$(nix flake metadata --json "$flake_ref" | jq -r .resolvedUrl)"

    IFS='.' read -r -a parts <<<"$attr_path_str"
    nix_list="["
    for p in "''${parts[@]}"; do nix_list+=" \"$p\""; done
    nix_list+=" ]"
    expr="let pkg = builtins.foldl' (acc: a: acc.\''${a}) (builtins.getFlake \"$flake_ref\") $nix_list; in pkg.withCache \"${baselineRef}\""

    echo "==> building $target restoring from baseline (${name})" >&2
    nix build --impure --expr "$expr" "$@" -L
  '';
}
