{
  system,
  pkgs,
  mkIncrementalGoPackage,
}:
# The "go bigger" Go test: kubernetes builds 6 real cmd/ components
# (kubeadm, kubelet, kube-apiserver, kube-controller-manager,
# kube-proxy, kube-scheduler) from one module — cold build 14m43s,
# same-source warm rebuild 4m17s (~3.4x). Its own patch
# (kubernetes-kubeadm-avoid-config-leak.patch) is a real, narrow
# single-file fix in cmd/kubeadm only — restoring from the unpatched
# cache and rebuilding the patched one takes 4m49s, close to the
# same-source number, confirming the other 5 components' build output
# wasn't invalidated by a change to a file only kubeadm depends on.
{
  nixpkgs-kubernetes = mkIncrementalGoPackage {
    name = "nixpkgs-kubernetes";
    inherit system pkgs;
    drv = pkgs.kubernetes;
  };
  nixpkgs-kubernetes-patched = mkIncrementalGoPackage {
    name = "nixpkgs-kubernetes";
    inherit system pkgs;
    drv = pkgs.kubernetes.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ../patches/kubernetes-kubeadm-avoid-config-leak.patch ];
    });
  };
}
