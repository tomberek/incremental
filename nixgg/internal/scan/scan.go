// Package scan enumerates the header set for a compile invocation by
// running `<cc> -MM -MG` and parsing the emitted makefile fragment.
//
// Results are cached under .nixgg/scans/<key>.{deps,out} where <key> is
// sha256(compiler + source + flags). Cache is invalidated when any
// file in the recorded dep list has an mtime newer than what we saw.
//
// Two callers of this package:
//   - The compile shim: needs the header list + the "project root" (a
//     common ancestor of cwd + every user-supplied -I dir) to stage
//     sources; also needs the -I flags rewritten to be relative to
//     that project root, and the store-prefixed -I flags kept verbatim.
//   - The scan cache itself doesn't need to be exported, but the
//     Result type is.
package scan

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/tbereknyei/nixgg/internal/paths"
)

// Header is a discovered dependency: `Abs` is the current on-disk
// location, `Rel` is where it should appear inside the staging dir
// (relative to the project root that Sources chose).
type Header struct {
	Abs, Rel string
}

// Result is the full output of a scan.
type Result struct {
	Headers []Header
	// ProjectRoot is the common ancestor of cwd + every user -I dir.
	// The staging dir mirrors this — headers land at
	//   $stagingDir/<rel-to-project-root>.
	ProjectRoot string
	// StagedIFlags are `-I<rel>` flags to be passed to gcc inside the
	// sandbox, relative to the staged project root. Always includes
	// "-I." so the source directory is on the include path.
	StagedIFlags []string
	// StoreIFlags are `-I/nix/store/...` flags passed verbatim (system
	// dependencies from wrapper env).
	StoreIFlags []string
}

// Run scans a single compile invocation.
//   - cc: absolute path to the compiler (matches TOOL — cc, gcc, c++, g++)
//   - source: caller's source file (relative to cwd is fine)
//   - flags: everything else on argv (no -c/-o).
//
// Uses the cache under l.Scans if all deps' mtimes match.
func Run(l paths.Layout, cc, source string, flags []string) (*Result, error) {
	if err := os.MkdirAll(l.Scans, 0o755); err != nil {
		return nil, err
	}
	key := cacheKey(cc, source, flags)
	depsPath := filepath.Join(l.Scans, key+".deps")
	outPath := filepath.Join(l.Scans, key+".out")

	if fresh, err := depsStillFresh(depsPath); err == nil && fresh {
		if body, err := os.ReadFile(outPath); err == nil {
			var r Result
			if err := decodeResult(body, &r); err == nil {
				return &r, nil
			}
		}
	}

	// Cache miss — do the real work.
	r, deps, err := runScanner(cc, source, flags)
	if err != nil {
		return nil, err
	}
	body, err := encodeResult(r)
	if err != nil {
		return nil, err
	}
	// Write cache best-effort. If it fails we still return the result.
	if err := writeAtomic(outPath, body); err == nil {
		_ = writeAtomic(depsPath, encodeDeps(deps))
	}
	return r, nil
}

// depEntry is one line in the .deps file: <abs>\t<mtime-nsec>.
type depEntry struct {
	abs   string
	mtime int64 // unix nanoseconds; -1 if the file was missing when scanned
}

func depsStillFresh(path string) (bool, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return false, err
	}
	// Format: one line per file, `<abs>\t<mtime-nsec>`. Batch the stats
	// to keep the syscall count linear.
	lines := bytes.Split(bytes.TrimRight(body, "\n"), []byte{'\n'})
	for _, line := range lines {
		tab := bytes.IndexByte(line, '\t')
		if tab < 0 {
			return false, errors.New("malformed .deps line")
		}
		abs := string(line[:tab])
		recorded := string(line[tab+1:])
		info, err := os.Stat(abs)
		if err != nil {
			return false, nil // vanished file → invalidate
		}
		cur := fmt.Sprintf("%d", info.ModTime().UnixNano())
		if cur != recorded {
			return false, nil
		}
	}
	return true, nil
}

func encodeDeps(entries []depEntry) []byte {
	var b bytes.Buffer
	for _, e := range entries {
		fmt.Fprintf(&b, "%s\t%d\n", e.abs, e.mtime)
	}
	return b.Bytes()
}

func cacheKey(cc, source string, flags []string) string {
	h := sha256.New()
	fmt.Fprintln(h, cc)
	fmt.Fprintln(h, source)
	// Preserve order — flag order can affect semantics.
	for _, f := range flags {
		fmt.Fprintln(h, f)
	}
	return hex.EncodeToString(h.Sum(nil))[:32]
}

// runScanner executes `gcc -MM -MG` and turns its output into a Result.
// The scanner runs in the caller's cwd; that's where relative headers
// live and where -I flags are interpreted.
func runScanner(cc, source string, flags []string) (*Result, []depEntry, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, nil, err
	}
	// Collect user-supplied include dirs from flags. Both attached
	// (-I/path) and separated (-I /path) forms; also -isystem, -iquote,
	// -idirafter, -include.
	includeDirs := extractIncludeDirs(flags)

	// The project root is the common ancestor of cwd + the source
	// dir + every non-store include dir. Include the source dir
	// up-front so cmake-style out-of-tree builds — `cc -c ../src/x.cc`
	// from a `build/` directory — get a projectRoot that contains
	// the source. Without this, `filepath.Rel(cwd, srcAbs)` returns
	// `../src/x.cc`, which then stages the file *outside* the tuID
	// dir and produces a broken thunk that references a path with
	// `..` in it. We widen for headers later too.
	srcAbs, err := filepath.Abs(source)
	if err != nil {
		return nil, nil, err
	}
	userDirs := []string{cwd, filepath.Dir(srcAbs)}
	storeDirs := []string{}
	for _, d := range includeDirs {
		abs := d
		if !filepath.IsAbs(abs) {
			abs = filepath.Join(cwd, d)
		}
		if strings.HasPrefix(abs, "/nix/store/") {
			storeDirs = append(storeDirs, abs)
		} else {
			userDirs = append(userDirs, abs)
		}
	}
	projectRoot := commonAncestor(userDirs)

	// Strip -M* dep-generation flags from the scanner's argv — we
	// supply our own -MM -MG -MF -.
	scanFlags := stripDepFlags(flags)

	// gcc -MM -MG emits `target.o: dep1 dep2 \\\n  dep3 ...`. We want
	// just the deps.
	cmd := exec.Command(cc, append([]string{"-MM", "-MG", "-MF", "-", source}, scanFlags...)...)
	cmd.Stderr = nil // best-effort — we tolerate cc's warnings
	out, err := cmd.Output()
	if err != nil {
		// Show stderr on failure so users can see what went wrong.
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = string(ee.Stderr)
		}
		return nil, nil, fmt.Errorf("scan-headers %s %s: %w\n%s", cc, source, err, stderr)
	}
	tokens := parseMakeDeps(out)

	// Resolve each token: absolute path, or search cwd + user -I dirs.
	// Widen projectRoot to cover any dep found outside its current span.
	var resolved []string
	for _, tok := range tokens {
		if tok == filepath.Base(source) || tok == source {
			continue
		}
		abs, ok := resolveDep(tok, userDirs)
		if !ok {
			continue // -MG bare name we couldn't find; ignore
		}
		if abs == srcAbs {
			continue
		}
		if strings.HasPrefix(abs, "/nix/store/") {
			continue // store header, referenced verbatim via -I flag
		}
		resolved = append(resolved, abs)
	}

	// Widen project root to include every resolved header.
	for _, abs := range resolved {
		projectRoot = widen(projectRoot, filepath.Dir(abs))
	}

	// Now build the Result.
	seen := make(map[string]bool)
	var headers []Header
	var deps []depEntry
	// Source itself is a dep for cache invalidation but not a header.
	deps = append(deps, statOr(srcAbs))
	for _, abs := range resolved {
		if seen[abs] {
			continue
		}
		seen[abs] = true
		rel, err := filepath.Rel(projectRoot, abs)
		if err != nil {
			return nil, nil, err
		}
		headers = append(headers, Header{Abs: abs, Rel: rel})
		deps = append(deps, statOr(abs))
	}
	// Sort headers by staging rel path so thunk content is stable.
	sort.Slice(headers, func(i, j int) bool { return headers[i].Rel < headers[j].Rel })

	// -I flags rewritten relative to the project root.
	iflags := []string{"-I."}
	for _, p := range userDirs {
		if p == projectRoot {
			continue
		}
		rel, err := filepath.Rel(projectRoot, p)
		if err != nil {
			continue
		}
		iflags = append(iflags, "-I"+rel)
	}
	// Store dirs pass through unchanged.
	var storeFlags []string
	for _, d := range storeDirs {
		storeFlags = append(storeFlags, "-I"+d)
	}

	return &Result{
		Headers:      headers,
		ProjectRoot:  projectRoot,
		StagedIFlags: iflags,
		StoreIFlags:  storeFlags,
	}, deps, nil
}

func statOr(abs string) depEntry {
	info, err := os.Stat(abs)
	if err != nil {
		return depEntry{abs: abs, mtime: -1}
	}
	return depEntry{abs: abs, mtime: info.ModTime().UnixNano()}
}

// extractIncludeDirs walks flags and pulls out user-supplied include
// paths from all the -I family (both attached and separated forms).
func extractIncludeDirs(flags []string) []string {
	var out []string
	pathFlags := map[string]bool{
		"-I": true, "-isystem": true, "-iquote": true,
		"-idirafter": true, "-include": true,
	}
	for i := 0; i < len(flags); i++ {
		f := flags[i]
		if pathFlags[f] && i+1 < len(flags) {
			out = append(out, flags[i+1])
			i++
			continue
		}
		if strings.HasPrefix(f, "-I") && len(f) > 2 {
			out = append(out, f[2:])
		}
	}
	return out
}

func stripDepFlags(flags []string) []string {
	var out []string
	oneArg := map[string]bool{"-M": true, "-MM": true, "-MG": true, "-MP": true, "-MD": true, "-MMD": true}
	twoArg := map[string]bool{"-MF": true, "-MT": true, "-MQ": true}
	for i := 0; i < len(flags); i++ {
		f := flags[i]
		if oneArg[f] {
			continue
		}
		if twoArg[f] {
			i++ // skip the value too
			continue
		}
		out = append(out, f)
	}
	return out
}

func parseMakeDeps(out []byte) []string {
	// Join line-continuations first.
	var buf bytes.Buffer
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := sc.Bytes()
		line = bytes.TrimRight(line, " \t")
		if len(line) > 0 && line[len(line)-1] == '\\' {
			buf.Write(line[:len(line)-1])
			buf.WriteByte(' ')
			continue
		}
		buf.Write(line)
		buf.WriteByte(' ')
	}
	// Strip the "target:" prefix.
	joined := buf.String()
	if colon := strings.IndexByte(joined, ':'); colon >= 0 {
		joined = joined[colon+1:]
	}
	// Split on whitespace.
	var toks []string
	for _, f := range strings.Fields(joined) {
		toks = append(toks, f)
	}
	return toks
}

func resolveDep(tok string, userDirs []string) (string, bool) {
	// Both branches must return a *cleaned* absolute path: gcc -MM
	// emits paths like "common/../common/zstd_deps.h" that resolve to
	// the same underlying file as "common/zstd_deps.h", and we dedup
	// downstream on the abs string. filepath.Clean collapses "..".
	if filepath.IsAbs(tok) {
		clean := filepath.Clean(tok)
		if _, err := os.Stat(clean); err == nil {
			return clean, true
		}
		return "", false
	}
	for _, d := range userDirs {
		p := filepath.Join(d, tok) // Join cleans
		if _, err := os.Stat(p); err == nil {
			abs, err := filepath.Abs(p)
			if err == nil {
				return filepath.Clean(abs), true
			}
		}
	}
	return "", false
}

// commonAncestor returns the longest path that's a prefix of every
// input. Returns "/" if there's no shared prefix.
func commonAncestor(dirs []string) string {
	if len(dirs) == 0 {
		return "/"
	}
	root := filepath.Clean(dirs[0])
	for _, d := range dirs[1:] {
		root = widen(root, d)
	}
	return root
}

// widen shrinks `root` until `dir` is a descendant (or equal).
func widen(root, dir string) string {
	dir = filepath.Clean(dir)
	for !isPrefixOfPath(root, dir) {
		parent := filepath.Dir(root)
		if parent == root {
			return "/"
		}
		root = parent
	}
	return root
}

func isPrefixOfPath(root, path string) bool {
	if root == path {
		return true
	}
	if root == "/" {
		return true
	}
	return strings.HasPrefix(path, root+string(filepath.Separator))
}

// The scan cache stores enough to reconstruct a Result without redoing
// the fs walk. We use a compact newline-delimited format instead of
// JSON to keep parse cost low.
//
//   line 0:   PROJECT_ROOT=<path>
//   line 1..: STAGED_IFLAG=<flag>  (repeated, order preserved)
//   line ..:  STORE_IFLAG=<flag>   (repeated)
//   line ..:  HEADER=<abs>\t<rel>  (repeated)
func encodeResult(r *Result) ([]byte, error) {
	var b bytes.Buffer
	fmt.Fprintf(&b, "PROJECT_ROOT=%s\n", r.ProjectRoot)
	for _, f := range r.StagedIFlags {
		fmt.Fprintf(&b, "STAGED_IFLAG=%s\n", f)
	}
	for _, f := range r.StoreIFlags {
		fmt.Fprintf(&b, "STORE_IFLAG=%s\n", f)
	}
	for _, h := range r.Headers {
		fmt.Fprintf(&b, "HEADER=%s\t%s\n", h.Abs, h.Rel)
	}
	return b.Bytes(), nil
}

func decodeResult(body []byte, r *Result) error {
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "PROJECT_ROOT="):
			r.ProjectRoot = strings.TrimPrefix(line, "PROJECT_ROOT=")
		case strings.HasPrefix(line, "STAGED_IFLAG="):
			r.StagedIFlags = append(r.StagedIFlags, strings.TrimPrefix(line, "STAGED_IFLAG="))
		case strings.HasPrefix(line, "STORE_IFLAG="):
			r.StoreIFlags = append(r.StoreIFlags, strings.TrimPrefix(line, "STORE_IFLAG="))
		case strings.HasPrefix(line, "HEADER="):
			rest := strings.TrimPrefix(line, "HEADER=")
			tab := strings.IndexByte(rest, '\t')
			if tab < 0 {
				return errors.New("malformed HEADER line")
			}
			r.Headers = append(r.Headers, Header{Abs: rest[:tab], Rel: rest[tab+1:]})
		}
	}
	return sc.Err()
}

func writeAtomic(dst string, body []byte) error {
	f, err := os.CreateTemp(filepath.Dir(dst), filepath.Base(dst)+".tmp.*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err := f.Write(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(name, dst)
}
