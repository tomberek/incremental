// Package paths holds the on-disk layout constants for a nixgg workspace.
//
// A workspace is anchored at $NIXGG_THUNKS_DIR (default $PWD/.nixgg/thunks).
// Everything else — srcs/, scans/, symlinks/ — lives alongside it under
// the same .nixgg/ parent, unless overridden by env.
package paths

import (
	"os"
	"path/filepath"
)

// Layout resolves the standard set of cache directories from env.
// Zero value is invalid; use Resolve.
type Layout struct {
	Thunks    string // .nixgg/thunks/
	Srcs      string // .nixgg/srcs/
	Scans     string // .nixgg/scans/
	Symlinks  string // .nixgg/symlinks/
	Promoted  string // .nixgg/promoted/ — sha1(abs-path) → store path
}

// Resolve reads NIXGG_THUNKS_DIR (or defaults to $PWD/.nixgg/thunks) and
// derives sibling dirs from its parent. Each dir can be overridden
// individually via NIXGG_{SRCS,SCANS,SYMLINKS}_DIR.
func Resolve() (Layout, error) {
	thunks := os.Getenv("NIXGG_THUNKS_DIR")
	if thunks == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return Layout{}, err
		}
		thunks = filepath.Join(cwd, ".nixgg", "thunks")
	}
	parent := filepath.Dir(thunks)
	return Layout{
		Thunks:   thunks,
		Srcs:     envOr("NIXGG_SRCS_DIR", filepath.Join(parent, "srcs")),
		Scans:    envOr("NIXGG_SCANS_DIR", filepath.Join(parent, "scans")),
		Symlinks: envOr("NIXGG_SYMLINKS_DIR", filepath.Join(parent, "symlinks")),
		Promoted: envOr("NIXGG_PROMOTED_DIR", filepath.Join(parent, "promoted")),
	}, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
