# Pure-eval-compatible replacement for `builtins.storePath`.
#
# `builtins.storePath` refuses to run under `--pure-eval`. This helper
# takes the same input (a string spelling `/nix/store/…`) and returns a
# value that Nix accepts as a store reference under pure eval, without
# reading the filesystem or calling the disallowed builtin.
#
# It's implemented with two "unsafe" builtins:
#   1. `unsafeDiscardStringContext`: strip any existing string context.
#   2. `appendContext`: attach fresh store context tagged as a path
#      reference to the original path.
#
# The result behaves like `builtins.storePath` in every downstream use
# we care about (interpolation, `${p}/bin/x`, being a `derivation`
# input, showing up in `_storeDeps`). Unlike `builtins.storePath` it
# does NOT verify the path exists — callers must ensure that.
path:
let
  contextFree = builtins.unsafeDiscardStringContext path;
in
  builtins.appendContext contextFree { ${contextFree} = { path = true; }; }
