package cli

import (
	"fmt"
	"os"
	"path/filepath"
)

// cmdEnv prints shell `export` lines that a caller can `eval` to get
// nixgg's shims on PATH. It does NOT bootstrap NIXGG_REAL_CC etc —
// that's done by sourcing the flake's env-shell (or the cached copy
// in ~/.cache/nixgg/mosh-env.sh).
//
// The bash implementation used to bootstrap itself; the Go version
// leaves that to the flake and integration scripts.
func cmdEnv() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	root := filepath.Dir(filepath.Dir(exe))
	shims := filepath.Join(root, "shims")
	fmt.Printf("export NIXGG_ROOT=%q\n", root)
	fmt.Printf("export PATH=%q:\"$PATH\"\n", shims)
	fmt.Println("export CC=cc")
	fmt.Println("export CXX=c++")
	return nil
}
