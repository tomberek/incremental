# Incremental builds

```
# Build normally.
$ nix build .#thing

# make a change the source code
echo "// hi" >> go/main.go

# rebuild of the dirty tree is faster
$ nix build .#thing --override-input cache github:tomberek/incremental -L
```

## Zig

```
# Build normally.
$ nix build .#zig

# make a change to the source code
echo "// hi" >> zig/main.zig

# rebuild of the dirty tree is faster
$ nix build .#zig --override-input cache github:tomberek/incremental -L
```
