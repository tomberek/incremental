# Build lua (just the `lua` binary; luac is left for a follow-up)
# through mkNixggBuild, exercising a real multi-TU / archive project
# inside a builder-rpc-v0 sandbox.
#
# Uses `make lua` — the recipe transitively builds all TU .o files,
# the liblua.a archive, and then links `lua`. Each intermediate is
# emitted as its own drv (compile shim for TUs, archive shim for
# liblua.a, link shim for lua). Nix resolves the whole graph via
# builtins.outputOf.
{
  mkNixggBuild,
  fetchurl,
  stdenv,
}:

let
  lua-src = stdenv.mkDerivation {
    name = "lua-5.4.7-src";
    src = fetchurl {
      url = "https://www.lua.org/ftp/lua-5.4.7.tar.gz";
      # Placeholder — filled in on first build via the .drv hash.
      hash = "sha256-n79eKO+GxphY9tPTTszDLpEcGii0Eg/z6EqqcM+/HjA=";
    };
    installPhase = ''
      cp -r . $out
    '';
    phases = [ "unpackPhase" "installPhase" ];
  };
in

mkNixggBuild {
  pname = "lua";
  version = "5.4.7";
  src = lua-src;
  target = "lua";
  # $NIX_BUILD_CORES is what Nix sets; make -j$(nproc) doesn't work
  # inside the sandbox (no coreutils on the default path).
  buildCommand = ''
    cd src
    make lua CC=cc MYCFLAGS="-DLUA_USE_LINUX"
  '';
}
