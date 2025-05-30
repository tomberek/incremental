# Incremental builds

An approach to have incremental builds, re-using outputs/caches from a previous build.

Override the input of the "cache" to an earlier version of the same flake. This can be a clean git checkout to make dirty-tree builds faster, or a previous build, or one based on the date, whatever works for you.

```
# Build normally.
$ nix build .#thing

# make a change the source code
echo "// hi" >> golang/main.go

# rebuild of the dirty tree is faster
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#golang
```

## Zig

```
# Build normally.
$ nix build .#zig

# make a change to the source code
echo "// hi" >> zig/main.zig

# rebuild of the dirty tree is faster
$ nix build --override-input cache "git+file://$PWD?ref=HEAD" -L .#zig

```
