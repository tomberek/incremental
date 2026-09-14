{
  system,
  pkgs,
  mkIncrementalHaskellPackage,
}:
mkIncrementalHaskellPackage {
  name = "haskell";
  inherit system pkgs;
  drv = pkgs.haskellPackages.pandoc-cli;
}
