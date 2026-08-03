# Smoke test: build hello.cc through mkNixggBuild.
#
# Consumer view: `nix build .#hello` produces the compiled binary
# in the store, invisible to the caller whether one drv or ten got
# involved.
#
# Under the hood: the outer .drv-producing derivation runs a
# compile+link inside builder-rpc-v0. Compile shim emits one JSON
# drv per TU (here: one, for hello.cc → hello.o). Link shim emits
# its own JSON drv and calls submit-output. Consumer resolves via
# builtins.outputOf.
{
  mkNixggBuild,
  runCommand,
}:

let
  # Source is embedded so this file doesn't depend on paths outside
  # the flake root (which would make `nix build .#hello` complain
  # about impurity).
  helloSrc = builtins.toFile "hello.cc" ''
    #include <cstdio>

    int main() {
      std::printf("Hello from a nixgg dyn-drv build!\n");
      return 0;
    }
  '';

  # mkNixggBuild expects `src` to be a directory. Wrap the single
  # .cc file into a one-file tree.
  helloTree = runCommand "hello-src" { } ''
    mkdir -p $out
    cp ${helloSrc} $out/hello.cc
  '';
in

mkNixggBuild {
  pname = "hello";
  version = "0";
  src = helloTree;
  target = "hello";
  buildCommand = ''
    c++ -O2 -c hello.cc -o hello.o
    c++ hello.o -o hello
  '';
}
