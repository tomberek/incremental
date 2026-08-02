// Package classify inspects a compile input symlink and reports what
// kind of nixgg artifact (if any) it references.
//
// A caller-visible target is one of:
//   - Store    → symlink resolves to /nix/store/…-tu-foo.o/…
//                (already realised; use the store path as a reference)
//   - Thunk    → symlink resolves to .../thunks/<id>.nix
//                (not yet realised; the link/ar thunk `import`s it)
//   - Regular  → real file or symlink to something nixgg doesn't own
//                (passthrough — link/ar can't include it in a thunk)
//   - Absent   → the path doesn't exist at all
package classify

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/tbereknyei/nixgg/internal/paths"
	"github.com/tbereknyei/nixgg/internal/thunk"
)

// Kind labels a classification outcome.
type Kind int

const (
	Absent Kind = iota
	Regular
	Store
	Thunk
)

func (k Kind) String() string {
	switch k {
	case Absent:
		return "absent"
	case Regular:
		return "regular"
	case Store:
		return "store"
	case Thunk:
		return "thunk"
	}
	return "?"
}

// Result carries the classification plus a reference that means
// different things per kind:
//   - Store: canonical /nix/store/<hash>-<name> root (alt-store prefix
//     stripped so the reference is portable).
//   - Thunk: absolute path to the .nix thunk file.
//   - Regular / Absent: empty.
type Result struct {
	Kind Kind
	Ref  string
	// ThunkID is set when Kind == Store AND we know which thunk file
	// produced this output (only populated for promoted regular files
	// today — a real symlink → /nix/store/... doesn't carry that
	// association). Empty otherwise.
	ThunkID string
}

// Target classifies a single path.
//
// altStorePrefix is the on-disk root of the alt store (e.g.
// "/tmp/nixgg-store"), or "" for a system store. We strip it when
// reporting store paths so the reference is always the canonical
// /nix/store/... form that Nix expects.
//
// l is the paths.Layout — needed to consult the "promoted" registry,
// which records regular-file targets that came from a store output.
// Force copies bytes into the working tree (rather than symlinking)
// so make's mtime dependency check works, but downstream link/ar
// shims still need to identify the file's store origin. Pass a
// zero-value Layout to skip the registry check.
func Target(path, altStorePrefix string, l paths.Layout) Result {
	info, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return Result{Kind: Absent}
		}
		return Result{Kind: Regular}
	}
	if info.Mode()&os.ModeSymlink == 0 {
		// Regular file on disk. Was it promoted from a store output?
		if l.Promoted != "" {
			if info := thunk.LookupPromoted(l, path); info != nil {
				return Result{Kind: Store, Ref: info.StorePath, ThunkID: string(info.ThunkID)}
			}
		}
		return Result{Kind: Regular}
	}

	dest, err := readlinkFollow(path)
	if err != nil {
		return Result{Kind: Regular}
	}

	// Strip alt-store on-disk prefix to reveal canonical /nix/store/...
	canonical := dest
	if altStorePrefix != "" && strings.HasPrefix(dest, altStorePrefix+"/nix/store/") {
		canonical = strings.TrimPrefix(dest, altStorePrefix)
	}
	if strings.HasPrefix(canonical, "/nix/store/") {
		return Result{Kind: Store, Ref: storeRootOf(canonical)}
	}
	if strings.HasSuffix(dest, ".nix") {
		return Result{Kind: Thunk, Ref: dest}
	}
	return Result{Kind: Regular}
}

// storeRootOf strips a store subpath down to its /nix/store/<hash>-<name>
// prefix — the "store root" that gets wrapped in builtins.storePath.
func storeRootOf(p string) string {
	// p is /nix/store/<rest>. Keep the first two path components.
	rest := strings.TrimPrefix(p, "/nix/store/")
	if slash := strings.IndexByte(rest, '/'); slash >= 0 {
		rest = rest[:slash]
	}
	return "/nix/store/" + rest
}

// readlinkFollow returns the final resolved target. We use EvalSymlinks
// because a symlink can chain (e.g. output → thunk → nothing yet). If
// the chain leads to a nonexistent path we fall back to the raw target.
func readlinkFollow(path string) (string, error) {
	resolved, err := filepath.EvalSymlinks(path)
	if err == nil {
		return resolved, nil
	}
	return os.Readlink(path)
}
