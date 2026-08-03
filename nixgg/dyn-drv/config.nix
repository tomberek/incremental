{ pkgs ? import <nixpkgs> { } }:
rec {
  inherit (pkgs) coreutils bash;
  shell = "${pkgs.bash}/bin/bash";
  path = builtins.concatStringsSep ":" [
    "${pkgs.coreutils}/bin"
    "${pkgs.bash}/bin"
    "${pkgs.gnused}/bin"
    "${pkgs.gnugrep}/bin"
    "${pkgs.gcc}/bin"
    "${pkgs.binutils}/bin"
  ];
  system = builtins.currentSystem;

  # Raw derivation that mirrors the PR's dyn-drv/config.nix `mkDerivation`.
  # Deliberately not stdenv: builder-rpc-v0 derivations must run without
  # $out being set, which trips stdenv's _assignFirst.
  mkDerivation =
    attrs:
    let
      buildCommand = attrs.buildCommand or (throw "buildCommand required");
      pnix = attrs.patchedNix or (throw "patchedNix required");
    in
    derivation (
      (builtins.removeAttrs attrs [ "buildCommand" "patchedNix" ]) // {
        inherit system;
        builder = shell;
        args = [ "-c" buildCommand ];
        PATH = "${pnix}/bin:${path}";
      }
    );
}
