{
  system,
  pkgs,
  mkIncrementalCcachePackage,
}:
mkIncrementalCcachePackage {
  name = "hello-ccache";
  inherit system pkgs;
  autotools = true;
  drv = pkgs.hello.override { stdenv = pkgs.ccacheStdenv; };
}
