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

// realiseAndPromote runs `nix build --file <thunkPath>` on the target
// thunk, then walks every reachable thunk (via `./<id>.nix` imports)
// and re-points every caller-visible symlink in each manifest.
func realiseAndPromote(l paths.Layout, cfg *toolchain.Config, thunkPath, target string) error {
	// One nix build realises the whole DAG under this root.
	storePath, err := nixBuildFile(cfg, thunkPath)
	if err != nil {
		return err
	}
	// Promote the target symlink itself first.
	if err := promoteToStore(cfg, storePath, target); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "[nixgg force] %s -> %s\n", target, storePath)

	// Walk transitive `import ./<id>.nix` and promote every recorded
	// symlink under each thunk's manifest. Nix's eval cache means each
	// subsequent per-thunk build is essentially a store-path lookup.
	visited := map[string]bool{}
	var walk func(t string) error
	walk = func(t string) error {
		if visited[t] {
			return nil
		}
		visited[t] = true
		body, err := os.ReadFile(t)
		if err != nil {
			return nil // stale reference; ignore
		}
		for _, sib := range findRelativeImports(body) {
			child := filepath.Join(filepath.Dir(t), sib)
			if _, err := os.Stat(child); err != nil {
				continue
			}
			// Realise the child (eval-cache hit if nothing changed).
			childStore, err := nixBuildFile(cfg, child)
			if err != nil {
				fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", child, err)
				continue
			}
			// Promote every recorded symlink under this child's manifest.
			id := strings.TrimSuffix(filepath.Base(child), ".nix")
			if err := promoteManifest(l, cfg, id, childStore); err != nil {
				fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", id, err)
			}
			if err := walk(child); err != nil {
				return err
			}
		}
		return nil
	}
	if err := walk(thunkPath); err != nil {
		return err
	}
	// Also promote the root's manifest (in case there are more
	// caller-visible symlinks than just `target`).
	rootID := strings.TrimSuffix(filepath.Base(thunkPath), ".nix")
	if err := promoteManifest(l, cfg, rootID, storePath); err != nil {
		fmt.Fprintf(os.Stderr, "[nixgg force] %s: %v\n", rootID, err)
	}
	return nil
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
