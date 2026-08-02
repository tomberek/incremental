package cli

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/tbereknyei/nixgg/internal/classify"
	"github.com/tbereknyei/nixgg/internal/paths"
	"github.com/tbereknyei/nixgg/internal/toolchain"
)

// cmdForce: `nixgg force [--roots] [target…]`
//
// For each target: classify it; if it's a thunk symlink, walk the
// transitive `import ./<id>.nix` graph, realise the root via one
// `nix build --file <target-thunk>`, then re-point every recorded
// caller-visible symlink at the resulting store paths.
//
// --roots: skip explicit targets; scan .nixgg/thunks/ for thunks not
// imported by any other thunk (leaf outputs) and force them.
func cmdForce(args []string) error {
	var (
		thunksDir string
		roots     bool
		targets   []string
	)
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--thunks-dir":
			if i+1 >= len(args) {
				return fmt.Errorf("--thunks-dir requires an argument")
			}
			thunksDir = args[i+1]
			i++
		case "--roots":
			roots = true
		default:
			targets = append(targets, a)
		}
	}

	if thunksDir != "" {
		if err := os.Setenv("NIXGG_THUNKS_DIR", thunksDir); err != nil {
			return err
		}
	}
	l, err := paths.Resolve()
	if err != nil {
		return err
	}
	cfg, err := toolchain.FromEnv()
	if err != nil {
		return err
	}

	if roots {
		extra, err := findRootTargets(l)
		if err != nil {
			return err
		}
		targets = append(targets, extra...)
	}

	if len(targets) == 0 {
		return fmt.Errorf("force: no targets (pass targets or --roots)")
	}

	altPrefix := altStorePrefix(cfg.Store)

	for _, target := range targets {
		c := classify.Target(target, altPrefix)
		switch c.Kind {
		case classify.Absent:
			fmt.Fprintf(os.Stderr, "[nixgg force] no target %s\n", target)
			continue
		case classify.Regular:
			fmt.Fprintf(os.Stderr, "[nixgg force] %s is not a nixgg symlink\n", target)
			continue
		case classify.Store:
			fmt.Fprintf(os.Stderr, "[nixgg force] %s already realised (%s)\n", target, c.Ref)
			continue
		case classify.Thunk:
			if err := realiseAndPromote(l, cfg, c.Ref, target); err != nil {
				return err
			}
		}
	}
	return nil
}

// realiseAndPromote realises the target's whole DAG in one Nix
// invocation and re-points every caller-visible symlink at its store
// output.
//
// The critical optimisation vs a naïve implementation: **we call Nix
// exactly once**, not once per intermediate thunk. Nix's eval walks the
// `import ./<id>.nix` graph natively; all we do is:
//
//  1. Walk the graph locally to enumerate the child thunks.
//  2. Write a helper .nix that exposes each as a named attribute.
//  3. `nix build --file <helper> <attr>…` — Nix realises everything
//     under one process, one eval, one daemon session.
//  4. Parse the printed store paths, one per attr, and promote each
//     thunk's manifest.
func realiseAndPromote(l paths.Layout, cfg *toolchain.Config, thunkPath, target string) error {
	// 1. Walk transitively to collect every reachable thunk path.
	children, err := collectThunks(thunkPath)
	if err != nil {
		return err
	}

	// 2. Build the helper expression. Order matters because we correlate
	// printed store paths back to thunks by position.
	helper, err := writeForceHelper(l, thunkPath, children)
	if err != nil {
		return err
	}
	defer os.Remove(helper)

	// 3. One nix build for the whole DAG.
	attrs := make([]string, 0, 1+len(children))
	attrs = append(attrs, "root")
	for i := range children {
		attrs = append(attrs, fmt.Sprintf("t%d", i))
	}
	storePaths, err := nixBuildAttrs(cfg, helper, attrs)
	if err != nil {
		return err
	}
	if len(storePaths) != len(attrs) {
		return fmt.Errorf("force: expected %d store paths, got %d", len(attrs), len(storePaths))
	}

	// 4. Promote symlinks.
	rootStore := storePaths[0]
	if err := promoteToStore(cfg, rootStore, target); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[nixgg force] %s -> %s\n", target, rootStore)

	// Root manifest — extra caller-visible symlinks that reference the
	// same thunk (e.g. two different make targets that hit the same
	// content-hash).
	rootID := strings.TrimSuffix(filepath.Base(thunkPath), ".nix")
	if err := promoteManifest(l, cfg, rootID, rootStore); err != nil {
		fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", rootID, err)
	}

	// Child manifests.
	for i, child := range children {
		childStore := storePaths[i+1]
		id := strings.TrimSuffix(filepath.Base(child), ".nix")
		if err := promoteManifest(l, cfg, id, childStore); err != nil {
			fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", id, err)
		}
	}
	return nil
}

// collectThunks walks import ./<id>.nix transitively from root, and
// returns every child thunk path in a deterministic order. The root
// itself is NOT in the returned slice.
func collectThunks(root string) ([]string, error) {
	visited := map[string]bool{root: true}
	var out []string
	var walk func(t string) error
	walk = func(t string) error {
		body, err := os.ReadFile(t)
		if err != nil {
			return nil // stale reference; ignore
		}
		dir := filepath.Dir(t)
		for _, sib := range findRelativeImports(body) {
			child := filepath.Join(dir, sib)
			if visited[child] {
				continue
			}
			visited[child] = true
			if _, err := os.Stat(child); err != nil {
				continue
			}
			out = append(out, child)
			if err := walk(child); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(root); err != nil {
		return nil, err
	}
	return out, nil
}

// writeForceHelper emits a temp .nix file that exposes the root thunk
// plus every child under numbered attribute names (root, t0, t1, …).
// The file lives next to the root thunk so relative imports resolve.
func writeForceHelper(l paths.Layout, root string, children []string) (string, error) {
	var b strings.Builder
	b.WriteString("{\n")
	fmt.Fprintf(&b, "  root = import %q;\n", root)
	for i, c := range children {
		fmt.Fprintf(&b, "  t%d = import %q;\n", i, c)
	}
	b.WriteString("}\n")
	tmp, err := os.CreateTemp(filepath.Dir(root), "force-*.nix")
	if err != nil {
		return "", err
	}
	if _, err := tmp.WriteString(b.String()); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return "", err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return "", err
	}
	return tmp.Name(), nil
}

// nixBuildAttrs runs `nix build --file <helper> <attr>...` and returns
// the printed store paths in the same order as attrs.
func nixBuildAttrs(cfg *toolchain.Config, helper string, attrs []string) ([]string, error) {
	args := []string{"build", "-L", "--no-link", "--print-out-paths", "--file", helper}
	args = append(args, attrs...)
	cmd := exec.Command(cfg.Nix, args...)
	cmd.Env = append(os.Environ(),
		"NIX_REMOTE=",
		"NIX_CONFIG=experimental-features = nix-command flakes ca-derivations\nstore = "+cfg.Store+"\n",
	)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("nix build --file %s: %w", helper, err)
	}
	// Output is one store path per attr, in argument order.
	var paths []string
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if line != "" {
			paths = append(paths, line)
		}
	}
	return paths, nil
}

// relImportRE matches `import ./<32-hex>.nix` — the shape our thunks
// emit for sibling references. Deliberately narrow so we don't misfire
// on `import <nixpkgs>` or other non-thunk imports.
var relImportRE = regexp.MustCompile(`import \./([a-f0-9]+\.nix)`)

func findRelativeImports(body []byte) []string {
	matches := relImportRE.FindAllSubmatch(body, -1)
	seen := map[string]bool{}
	var out []string
	for _, m := range matches {
		s := string(m[1])
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

// promoteManifest reads the .nixgg/symlinks/<id> manifest, filters to
// still-existing symlinks, and re-points each at the store path.
func promoteManifest(l paths.Layout, cfg *toolchain.Config, id, storePath string) error {
	manifest := filepath.Join(l.Symlinks, id)
	f, err := os.Open(manifest)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		sym := sc.Text()
		if sym == "" {
			continue
		}
		info, err := os.Lstat(sym)
		if err != nil || info.Mode()&os.ModeSymlink == 0 {
			continue // user deleted or replaced
		}
		if err := promoteToStore(cfg, storePath, sym); err != nil {
			fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", sym, err)
			continue
		}
		fmt.Fprintf(os.Stderr, "[nixgg force] %s -> %s\n", sym, storePath)
	}
	return sc.Err()
}

// promoteToStore re-points target at storePath's on-disk location.
// The realised derivation always contains a single file whose basename
// equals the caller-visible symlink's basename (the shim set outName
// that way), so we can construct the source path directly.
func promoteToStore(cfg *toolchain.Config, storePath, target string) error {
	src := altStoreOnDisk(cfg.Store, storePath) + "/" + filepath.Base(target)
	if _, err := os.Stat(src); err != nil {
		return fmt.Errorf("expected %s to exist: %w", src, err)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	_ = os.Remove(target)
	return os.Symlink(src, target)
}

// findRootTargets scans thunks/ for .nix files not imported by any
// other .nix, then returns one symlink per root (from the manifest).
func findRootTargets(l paths.Layout) ([]string, error) {
	entries, err := os.ReadDir(l.Thunks)
	if err != nil {
		return nil, err
	}
	// Set of all thunk IDs.
	allIDs := map[string]bool{}
	// Union of all IDs referenced by any thunk's imports.
	referenced := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".nix") {
			continue
		}
		id := strings.TrimSuffix(e.Name(), ".nix")
		allIDs[id] = true
		body, err := os.ReadFile(filepath.Join(l.Thunks, e.Name()))
		if err != nil {
			continue
		}
		for _, sib := range findRelativeImports(body) {
			referenced[strings.TrimSuffix(sib, ".nix")] = true
		}
	}
	var targets []string
	for id := range allIDs {
		if referenced[id] {
			continue
		}
		// Root thunk. Pick any symlink from its manifest.
		manifest := filepath.Join(l.Symlinks, id)
		f, err := os.Open(manifest)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			if s := sc.Text(); s != "" {
				targets = append(targets, s)
				break
			}
		}
		f.Close()
	}
	return targets, nil
}

// nixBuildFile invokes `nix build --file <path>` against the configured
// store and returns the resulting store path. Wraps the daemon call —
// this is the only place we go to the store from the CLI path.
func nixBuildFile(cfg *toolchain.Config, thunkPath string) (string, error) {
	cmd := exec.Command(cfg.Nix, "build", "-L", "--no-link", "--print-out-paths", "--file", thunkPath)
	cmd.Env = append(os.Environ(),
		"NIX_REMOTE=",
		"NIX_CONFIG=experimental-features = nix-command flakes ca-derivations\nstore = "+cfg.Store+"\n",
	)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("nix build --file %s: %w", thunkPath, err)
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if lines[i] != "" {
			return lines[i], nil
		}
	}
	return "", fmt.Errorf("nix build produced no output")
}

// altStoreOnDisk / altStorePrefix are duplicated with shim/link.go
// because tucking them under an internal/util would just move the
// puzzle around. Sixteen lines, two callers, keep it local.
func altStoreOnDisk(storeURL, canonical string) string {
	const prefix = "local?root="
	if strings.HasPrefix(storeURL, prefix) {
		return strings.TrimPrefix(storeURL, prefix) + canonical
	}
	return canonical
}

func altStorePrefix(storeURL string) string {
	const prefix = "local?root="
	if strings.HasPrefix(storeURL, prefix) {
		return strings.TrimPrefix(storeURL, prefix)
	}
	return ""
}
