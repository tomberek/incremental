// Package stage materialises the source tree for a single compile into
// .nixgg/srcs/<tu-id>/, using hardlinks to share inodes with the working
// tree. The staging dir is referenced from the thunk as a relative Nix
// path (`srcTree = ../srcs/<tu-id>;`) so Nix imports it into the store
// at eval time — no `nix store add` in the shim.
//
// Reuse policy: the dir already exists AND every recorded entry's inode
// matches the current original AND no stale files remain → keep as-is.
// Anything else → nuke and repopulate. Inodes are the correctness
// signal: editors that write-then-rename break the hardlink, so the
// original's inode changes and we detect it.
package stage

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"

	"github.com/tbereknyei/nixgg/internal/paths"
)

// Entry pairs an absolute path in the working tree with the relative
// path where it should appear under the staging root.
type Entry struct {
	Abs, Rel string
}

// Result reports where the staging dir lives and whether we reused it.
// Callers that also want to skip re-writing a thunk can compare Reused.
type Result struct {
	Dir    string // absolute path to .nixgg/srcs/<tu-id>/
	Reused bool
}

// Sources materialises `entries` into l.Srcs/tuID/. Idempotent, safe to
// call concurrently on different tuIDs, MUST NOT be called concurrently
// on the same tuID (we don't lock).
func Sources(l paths.Layout, tuID string, entries []Entry) (Result, error) {
	dir := filepath.Join(l.Srcs, tuID)
	if err := os.MkdirAll(l.Srcs, 0o755); err != nil {
		return Result{}, err
	}

	if reuseOK(dir, entries) {
		return Result{Dir: dir, Reused: true}, nil
	}

	// Rebuild from scratch. Cheaper than trying to reconcile — hardlinks
	// are essentially free.
	if err := os.RemoveAll(dir); err != nil {
		return Result{}, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{}, err
	}
	for _, e := range entries {
		if err := hardlinkOrCopy(e.Abs, filepath.Join(dir, e.Rel)); err != nil {
			return Result{}, err
		}
	}
	return Result{Dir: dir, Reused: false}, nil
}

// reuseOK returns true iff dir has exactly the requested entries, each
// hardlinked to its current original.
func reuseOK(dir string, entries []Entry) bool {
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return false
	}

	// Inode-match every requested entry.
	want := make(map[string]bool, len(entries))
	for _, e := range entries {
		want[e.Rel] = true
		orig, err := statInode(e.Abs)
		if err != nil {
			return false
		}
		staged, err := statInode(filepath.Join(dir, e.Rel))
		if err != nil {
			return false
		}
		if orig != staged {
			return false
		}
	}

	// Guard against stale files (a header was #include-removed).
	have, err := listAllRelFiles(dir)
	if err != nil {
		return false
	}
	if len(have) != len(want) {
		return false
	}
	for _, rel := range have {
		if !want[rel] {
			return false
		}
	}
	return true
}

func statInode(path string) (uint64, error) {
	info, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	sys, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("stat: %s: no syscall.Stat_t", path)
	}
	return sys.Ino, nil
}

func listAllRelFiles(root string) ([]string, error) {
	var out []string
	prefix := root + string(filepath.Separator)
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		out = append(out, strings.TrimPrefix(path, prefix))
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(out)
	return out, nil
}

// hardlinkOrCopy tries os.Link first, falls back to a byte copy if the
// filesystems differ (EXDEV) or hardlinks are otherwise forbidden.
// We intentionally do NOT chmod the result — it's hardlinked to the
// original, so mode changes would affect the working tree.
func hardlinkOrCopy(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	if err := os.Link(src, dst); err == nil {
		return nil
	} else if !isCrossDeviceOrEPERM(err) {
		return err
	}
	// Cross-fs fallback.
	sf, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sf.Close()
	df, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer df.Close()
	if _, err := io.Copy(df, sf); err != nil {
		return err
	}
	return nil
}

func isCrossDeviceOrEPERM(err error) bool {
	var lerr *os.LinkError
	if errors.As(err, &lerr) {
		if errno, ok := lerr.Err.(syscall.Errno); ok {
			return errno == syscall.EXDEV || errno == syscall.EPERM
		}
	}
	return false
}

// TUID slugifies an output path into a filesystem-safe cache-dir name.
// "src/foo/bar.o" → "src-foo-bar"; the stem drops the .o suffix.
// Two different TUs never collide (different output = different key).
func TUID(output string) string {
	// Drop trailing .o if present; keep other extensions (.xo, .lo)
	// so redis's tests/modules objects don't clash with regular objects.
	stem := strings.TrimSuffix(output, ".o")
	// Replace path separators with '-', then scrub non-safe chars to '_'.
	var b strings.Builder
	b.Grow(len(stem))
	for _, r := range stem {
		switch {
		case r == '/':
			b.WriteByte('-')
		case r == '.' || r == '_' || r == '-' ||
			(r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	return b.String()
}
