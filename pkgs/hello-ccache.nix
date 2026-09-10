{
  system,
  pkgs,
  mkIncrementalCcacheAutotoolsPackage,
}:
mkIncrementalCcacheAutotoolsPackage {
  name = "hello-ccache";
  inherit system pkgs;
  drv = pkgs.hello.override { stdenv = pkgs.ccacheStdenv; };
}
