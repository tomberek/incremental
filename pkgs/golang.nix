{
  system,
  pkgs,
  mkIncrementalGoPackage,
}:
mkIncrementalGoPackage {
  name = "golang";
  inherit system pkgs;
  drv = pkgs.buildGoModule {
    name = "golang";
    src = pkgs.lib.cleanSource ../golang;
    vendorHash = "sha256-5xR9WCkpPpY9D0LR2mcdoOX34RqVpxJjgRwc4GEkGiE=";
  };
}
