# Build nixgg/example/ through mkNixggBuild (sandbox / dyn-drv mode).
#
# THIS IS THE SAME SOURCE the native path uses. Steps to see the two
# paths are equivalent:
#
#   # native:
#   cd nixgg/example
#   nix develop /path/to/nixgg -c bash -c 'NIXGG_AUTOFORCE=0 make'
#   # inspect .nixgg/thunks/*.nix → drv paths
#
#   # sandbox:
#   nix build /path/to/nixgg#hello --no-eval-cache
#   # inspect the drv chain: compile drvs land at the same store
#   # paths, link drv lands at the same store path.
#
# The mkNixggBuild wrapper adds one outer .drv.drv derivation (the
# text-mode "produce a drv" step) but every derivation inside is
# byte-identical to the native path.
{
  mkNixggBuild,
  lib,
}:

let
  # Cherry-pick the four example files: main.cc, util.cc, util.h,
  # Makefile. Using `../example` directly would drag the whole nixgg
  # tree into the store; filter narrows it.
  exampleSrc = lib.cleanSourceWith {
    src = ./../example;
    filter = path: type:
      let name = baseNameOf path; in
      name == "main.cc" || name == "util.cc" || name == "util.h"
      || name == "Makefile";
  };
in

mkNixggBuild {
  pname = "hello";
  version = "0";
  src = exampleSrc;
  target = "hello";
  # Same Makefile the native path uses. No divergent build script —
  # if it produces different drvs, that's a real bug in nixgg.
  buildCommand = "make";
}
