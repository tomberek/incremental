{ mkEcosystemPackage }:

# buildGoModule's own configurePhase sets $GOCACHE and only then
# runs postConfigure — mkIncrementalPackage's `phase` argument must
# be exactly that hook, so bake it in rather than making every
# caller rediscover it.
mkEcosystemPackage {
  cacheVars = [ "GOCACHE" ];
  phase = "postConfigure";
}
