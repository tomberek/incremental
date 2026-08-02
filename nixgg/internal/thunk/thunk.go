// Package thunk writes Nix expression files to .nixgg/thunks/<id>.nix
// and records the caller-visible symlinks that reference each one.
//
// A "thunk" is any Nix expression produced by a shim: compile, link,
// or archive. Its ID is sha256(expression body) truncated to 32 chars,
// so identical inputs collapse to the same file.
package thunk

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/tbereknyei/nixgg/internal/paths"
)

// ID is a 32-char lowercase hex hash of the expression body.
type ID string

// Compute derives an ID from an expression body. Same bytes → same ID.
func Compute(expr string) ID {
	sum := sha256.Sum256([]byte(expr))
	return ID(hex.EncodeToString(sum[:16]))
}

// Path returns the absolute file path for this thunk under the layout.
func (id ID) Path(l paths.Layout) string {
	return filepath.Join(l.Thunks, string(id)+".nix")
}

// Write persists the expression at .nixgg/thunks/<id>.nix if it doesn't
// already exist. Idempotent: same content is never rewritten.
//
// Uses tmp+rename so concurrent shim invocations that produce the same
// thunk don't race producing a half-written file.
func Write(l paths.Layout, id ID, expr string) (string, error) {
	if err := os.MkdirAll(l.Thunks, 0o755); err != nil {
		return "", err
	}
	dst := id.Path(l)
	if _, err := os.Stat(dst); err == nil {
		return dst, nil
	}
	tmp, err := os.CreateTemp(l.Thunks, string(id)+".tmp.*")
	if err != nil {
		return "", err
	}
	tmpName := tmp.Name()
	// On any error path, best-effort remove the tmp file.
	defer os.Remove(tmpName)
	if _, err := tmp.WriteString(expr); err != nil {
		tmp.Close()
		return "", err
	}
	if err := tmp.Close(); err != nil {
		return "", err
	}
	// Rename is atomic within a filesystem; on races the second write
	// loses to the first, but content is identical so it doesn't matter.
	if err := os.Rename(tmpName, dst); err != nil {
		// If dst appeared under us (another writer won the race), that's
		// fine — bytes match by construction.
		if _, statErr := os.Stat(dst); statErr == nil {
			return dst, nil
		}
		return "", err
	}
	return dst, nil
}

// LinkPlaceholder replaces `output` with a symlink pointing at the
// thunk file. Creates the parent dir if missing.
func LinkPlaceholder(output, thunkPath string) error {
	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return err
	}
	// os.Symlink refuses to overwrite. Best-effort remove first —
	// a stale target from a previous build is expected.
	_ = os.Remove(output)
	if err := os.Symlink(thunkPath, output); err != nil {
		return fmt.Errorf("symlink %s -> %s: %w", output, thunkPath, err)
	}
	return nil
}

// RecordSymlink appends the caller-visible symlink path to the manifest
// under .nixgg/symlinks/<id>. Idempotent (skips exact-match duplicates).
func RecordSymlink(l paths.Layout, id ID, output string) error {
	if err := os.MkdirAll(l.Symlinks, 0o755); err != nil {
		return err
	}
	abs, err := filepath.Abs(output)
	if err != nil {
		return err
	}
	manifest := filepath.Join(l.Symlinks, string(id))
	// Cheap dedup: read + scan. Manifests are small (a few dozen lines
	// max in practice) so this doesn't cost.
	if existing, err := os.ReadFile(manifest); err == nil {
		off := 0
		for off < len(existing) {
			end := off
			for end < len(existing) && existing[end] != '\n' {
				end++
			}
			if string(existing[off:end]) == abs {
				return nil // already recorded
			}
			off = end + 1
		}
	}
	f, err := os.OpenFile(manifest, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintln(f, abs)
	return err
}
