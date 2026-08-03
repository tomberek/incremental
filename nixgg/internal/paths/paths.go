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

// gitRootMarker is the name of the file/dir that marks a git worktree root.
// We check for `.git` (either a dir in the main worktree or a file for
// submodules/linked worktrees).
const gitRootMarker = ".git"

// Layout resolves the standard set of cache directories from env.
// Zero value is invalid; use Resolve.
type Layout struct {
	Thunks    string // .nixgg/thunks/
	Srcs      string // .nixgg/srcs/
	Scans     string // .nixgg/scans/
	Symlinks  string // .nixgg/symlinks/
	Promoted  string // .nixgg/promoted/ — sha1(abs-path) → store path
}

// Resolve returns the on-disk layout for the current nixgg workspace.
//
// Selection precedence:
//  1. $NIXGG_THUNKS_DIR if set (a top-level script pins one dir).
//  2. Walk up from $PWD looking for an existing `.nixgg/` directory.
//  3. Walk up from $PWD looking for a git root (`.git`); if found,
//     seed `.nixgg/` there. This makes recursive-make projects DWIM:
//     every shim in the descendant process tree lands in the same
//     thunks dir, so cross-directory sibling imports resolve.
//  4. Fall back to $PWD/.nixgg/thunks (no git, no ancestor .nixgg).
//
// Each subdir can be overridden individually via NIXGG_{SRCS,SCANS,
// SYMLINKS,PROMOTED}_DIR.
func Resolve() (Layout, error) {
	thunks := os.Getenv("NIXGG_THUNKS_DIR")
	if thunks == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return Layout{}, err
		}
		root, err := findWorkspaceRoot(cwd)
		if err != nil {
			return Layout{}, err
		}
		thunks = filepath.Join(root, "thunks")
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

// findWorkspaceRoot picks the directory that will hold `.nixgg/` for
// the current workspace. Preference:
//  1. Nearest ancestor with an existing `.nixgg/` directory.
//  2. Nearest ancestor with `.git`; seed `.nixgg/` there so recursive
//     submakes (deps/*, lib/, programs/) converge.
//  3. $PWD itself, if neither is found.
//
// Returns the absolute path to the `.nixgg/` dir (existing or newly
// created).
func findWorkspaceRoot(start string) (string, error) {
	if found, ok := findAncestor(start, ".nixgg", true); ok {
		return found, nil
	}
	if gitDir, ok := findAncestor(start, gitRootMarker, false); ok {
		root := filepath.Join(filepath.Dir(gitDir), ".nixgg")
		if err := os.MkdirAll(root, 0o755); err != nil {
			return "", err
		}
		return root, nil
	}
	return filepath.Join(start, ".nixgg"), nil
}

// findAncestor walks up from `start` looking for a filesystem entry
// named `name`. If `mustBeDir` is true, only directories match; else
// any entry (file, dir, symlink) matches — this is what we want for
// `.git`, which can be a dir (main worktree) or a file (submodule /
// linked worktree). Returns the absolute path to the entry on success.
func findAncestor(start, name string, mustBeDir bool) (string, bool) {
	dir := start
	for {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil {
			if !mustBeDir || info.IsDir() {
				return candidate, true
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
