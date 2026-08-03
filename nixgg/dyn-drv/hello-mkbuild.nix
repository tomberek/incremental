# Smoke test: build hello.cc through mkNixggBuild.
#
# Consumer view: `nix build .#hello.result` (or the equivalent
# --file/--expr form) produces the compiled binary in the store,
# invisible to the caller whether one drv or ten got involved.
#
# Under the hood: the outer .drv-producing derivation runs a
# compile+link inside builder-rpc-v0. Compile shim emits one JSON
# drv per TU (here: one, for hello.cc → hello.o). Link shim emits
# its own JSON drv and calls submit-output. Consumer resolves via
# builtins.outputOf.
{
  mkNixggBuild,
}:

mkNixggBuild {
  pname = "hello";
  version = "0";
  src = builtins.filterSource (path: type: baseNameOf path == "hello.cc") ./..;
  target = "hello";
  buildCommand = ''
    c++ -O2 -c hello.cc -o hello.o
    c++ hello.o -o hello
  '';
}
