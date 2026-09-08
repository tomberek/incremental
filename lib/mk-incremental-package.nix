{
  inputs,
  lib,
  mkIncremental,
  resolveCache,
}:
let
  # `phase` is whichever hook runs before the tool reads its cache dir.
  # Required: e.g. buildGoModule's own configurePhase sets $GOCACHE and
  # only then runs postConfigure, so golang needs that specific hook.
  mkIncrementalPackage =
    {
      name,
      system,
      cacheVars,
      drv,
      phase,
      pkgs, # nuke-refs comes from here
      cache ? inputs.cache,
      nuke ? true,
      keepIncremental ? !(cache ? packages),
      extraPostInstall ? (_: ""),
    }:
    let
      inc = mkIncremental {
        inherit
          name
          system
          cacheVars
          cache
          nuke
          keepIncremental
          ;
      };
    in
    drv.overrideAttrs (
      old:
      {
        outputs = (old.outputs or [ "out" ]) ++ inc.outputs;
        ${phase} = (old.${phase} or "") + inc.restore;
        # nuke-refs isn't on stdenv's PATH by default — added here so
        # callers can't forget it and hit "command not found" the one
        # time `nuke` actually fires (e.g. once keepIncremental flips).
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ lib.optional nuke pkgs.nukeReferences;
        # Restores from a build of a third party's own without touching
        # their flake inputs: `pkg.withCache "git+file://...?rev=<sha>"`.
        # keepIncremental is carried over explicitly, not re-defaulted —
        # it must stay fixed regardless of which cache is passed in, same
        # reason `outputs` must stay structurally constant (see above).
        passthru = (old.passthru or { }) // {
          withCache =
            cacheFlake:
            mkIncrementalPackage {
              inherit
                name
                system
                cacheVars
                drv
                phase
                pkgs
                nuke
                extraPostInstall
                ;
              keepIncremental = inc.keepIncremental;
              cache = resolveCache cacheFlake;
            };
          # The withCache call above, packaged as a `nix run`-able
          # derivation that needs neither a flake ref for this package
          # (baseline is this build's own already-fetched source,
          # inputs.self, pinned via its own narHash so it works even
          # on a dirty tree) nor edits to the target's flake.nix:
          #   nix run <this-flake>#<name>.passthru.asCacheApp -- <target>
          # Plain derivation, not `{ type = "app"; ... }` — nix run
          # only recognizes that shape under apps.<system>.<name>, not
          # at an arbitrary attrpath; a derivation with
          # meta.mainProgram set (which writeShellApplication does)
          # works at any attrpath instead.
          asCacheApp =
            let
              # path: needs a narHash to be treated as locked;
              # getFlake otherwise refuses it same as an unpinned rev.
              encodedNarHash = lib.replaceStrings [ "+" "/" "=" ] [ "%2B" "%2F" "%3D" ] inputs.self.narHash;
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
            };
        };
      }
      // lib.optionalAttrs (nuke || (extraPostInstall inc.isCached) != "") {
        postInstall = (old.postInstall or "") + inc.nukeScript + extraPostInstall inc.isCached;
      }
    );
in
mkIncrementalPackage
