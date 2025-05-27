# Incremental builds

An approach to have incremental builds, re-using outputs/caches from a previous build.

```
# Build normally.
$ nix build .#thing

# make a change the source code
echo "// hi" >> golang/main.go

# rebuild of the dirty tree is faster
$ nix build .#golang --override-input cache github:tomberek/incremental -L
```
