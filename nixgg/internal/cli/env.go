package cli

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// cmdEnv prints shell `export` lines that a caller can `eval` to fully
// bootstrap nixgg from a plain shell:
//
//	eval "$(/path/to/nixgg/bin/nixgg env)"
//	cd my-project && nixgg build --target foo -- make
//
// What's set:
//   - NIXGG_ROOT and PATH prepended with shims/ (so make → cc → us).
//   - NIXGG_REAL_CC, NIXGG_NIX, NIXGG_NIX_HELPERS, NIXGG_COMPILER_ROOT,
//     NIXGG_BASH_ROOT, NIXGG_COREUTILS_ROOT — the toolchain roots that
//     every shim needs. Bootstrapped from the flake's `env-shell` output
//     if not already set (idempotent — respects env if you sourced
//     env-shell yourself).
//   - NIXGG_STORE (default `local?root=/tmp/nixgg-store`, override with
//     $NIXGG_STORE or --store).
//   - CC=cc, CXX=c++ (so recipes that consult $CC find our shims by
//     the argv[0] name we understand).
//
// Flags:
//
//	--store <url>       override the default alt store URL
//	--print-only        don't try to bootstrap missing vars via nix build
//
// The intended use is `eval $(nixgg env)` from your shell, or sourcing
// the printed lines into a script — everything a wrapper like lua.sh
// would set up manually.
func cmdEnv(args []string) error {
	var (
		storeOverride string
		printOnly     bool
	)
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--store":
			if i+1 >= len(args) {
				return fmt.Errorf("--store requires an argument")
			}
			storeOverride = args[i+1]
			i++
		case "--print-only":
			printOnly = true
		case "-h", "--help":
			fmt.Fprint(os.Stderr, `usage: nixgg env [--store <url>] [--print-only]

Prints shell `+"`export`"+` lines that fully bootstrap nixgg. Intended use:

    eval "$(nixgg env)"

If required NIXGG_* vars aren't already set in the environment, env
tries to build them from the flake at ../flake.nix (relative to the
nixgg binary). --print-only disables that fallback: env only prints
what it already knows and errors out if anything's missing.
`)
			return nil
		default:
			return fmt.Errorf("unknown flag %q", args[i])
		}
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	root := filepath.Dir(filepath.Dir(exe)) // bin/nixgg → ..
	shims := filepath.Join(root, "shims")

	// Toolchain env: honor what's already set; bootstrap from
	// .#env-shell for anything missing.
	env, err := loadToolchainEnv(root, printOnly)
	if err != nil {
		return err
	}

	// NIXGG_STORE: CLI flag > env > default alt store.
	store := storeOverride
	if store == "" {
		store = os.Getenv("NIXGG_STORE")
	}
	if store == "" {
		store = "local?root=/tmp/nixgg-store"
	}

	// Print in an order that's readable in a terminal and safe to eval.
	w := bufio.NewWriter(os.Stdout)
	defer w.Flush()
	fmt.Fprintf(w, "export NIXGG_ROOT=%s\n", shellQuote(root))
	// PATH gets both shims/ (so make → cc → us) AND bin/ (so the user
	// can call `nixgg build …` by name). Order: bin first so `nixgg` is
	// unambiguous even if a shim symlink named `nixgg` ever existed.
	bin := filepath.Join(root, "bin")
	fmt.Fprintf(w, "export PATH=%s:%s:${PATH}\n", shellQuote(bin), shellQuote(shims))
	fmt.Fprintln(w, "export CC=cc")
	fmt.Fprintln(w, "export CXX=c++")
	fmt.Fprintf(w, "export NIXGG_STORE=%s\n", shellQuote(store))
	// The toolchain vars — sorted for stable output.
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sortStrings(keys)
	for _, k := range keys {
		fmt.Fprintf(w, "export %s=%s\n", k, shellQuote(env[k]))
	}
	return nil
}

// loadToolchainEnv returns the NIXGG_* toolchain vars that every shim
// needs. Any missing vars are filled in by building and reading the
// flake's `.#env-shell` output. `printOnly` disables that fallback.
func loadToolchainEnv(root string, printOnly bool) (map[string]string, error) {
	required := []string{
		"NIXGG_REAL_CC", "NIXGG_NIX", "NIXGG_NIX_HELPERS",
		"NIXGG_COMPILER_ROOT", "NIXGG_BASH_ROOT", "NIXGG_COREUTILS_ROOT",
	}
	optional := []string{
		"NIXGG_PATCHED_NIX", "NIXGG_TOOLCHAIN_PATHS",
	}
	env := make(map[string]string)
	var missing []string
	for _, k := range required {
		if v := os.Getenv(k); v != "" {
			env[k] = v
		} else {
			missing = append(missing, k)
		}
	}
	for _, k := range optional {
		if v := os.Getenv(k); v != "" {
			env[k] = v
		}
	}
	if len(missing) == 0 {
		return env, nil
	}
	if printOnly {
		return nil, fmt.Errorf("missing env: %v (run without --print-only to bootstrap from flake)", missing)
	}

	// Bootstrap. Locate the flake next to us; run
	//   nix build <flake>#env-shell --no-link --print-out-paths
	// then parse the resulting shell fragment.
	flake, err := findFlake(root)
	if err != nil {
		return nil, fmt.Errorf("bootstrap: %w", err)
	}
	nix, err := findNix()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(nix, "build", flake+"#env-shell", "--no-link", "--print-out-paths")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("nix build %s#env-shell: %w", flake, err)
	}
	envPath := strings.TrimSpace(string(out))
	if envPath == "" {
		return nil, fmt.Errorf("nix build %s#env-shell returned nothing", flake)
	}
	parsed, err := parseExportFile(envPath)
	if err != nil {
		return nil, err
	}
	for _, k := range append(required, optional...) {
		if v, ok := parsed[k]; ok {
			env[k] = v
		}
	}
	// Verify required vars are now filled in.
	var stillMissing []string
	for _, k := range required {
		if env[k] == "" {
			stillMissing = append(stillMissing, k)
		}
	}
	if len(stillMissing) > 0 {
		return nil, fmt.Errorf("env-shell %s didn't set: %v", envPath, stillMissing)
	}
	return env, nil
}

// findFlake locates a flake.nix in `root` or a parent directory. Falls
// back to `root` itself if no flake.nix is found — the caller's `nix
// build` will produce a clear error in that case.
func findFlake(root string) (string, error) {
	dir := root
	for i := 0; i < 5; i++ {
		if _, err := os.Stat(filepath.Join(dir, "flake.nix")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("no flake.nix found near %s", root)
}

// findNix returns the `nix` binary to invoke for bootstrapping. Prefers
// $NIX (explicit user override) then whatever's on PATH.
func findNix() (string, error) {
	if p := os.Getenv("NIX"); p != "" {
		return p, nil
	}
	p, err := exec.LookPath("nix")
	if err != nil {
		return "", fmt.Errorf("no `nix` on PATH; install Nix or set $NIX")
	}
	return p, nil
}

// parseExportFile reads a shell fragment full of `export FOO="bar"` and
// returns FOO → bar. Handles the shapes the flake's writeTextFile
// output uses: `export KEY="value"` and `export KEY=value` with the
// value containing spaces + no shell metacharacters we care about.
//
// This is deliberately narrow; it's not a shell parser. If the flake
// output diverges, extend here.
func parseExportFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	out := make(map[string]string)
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if !strings.HasPrefix(line, "export ") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		k := line[:eq]
		v := line[eq+1:]
		// Strip a single surrounding pair of quotes.
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		out[k] = v
	}
	return out, sc.Err()
}

// shellQuote wraps a value in single quotes safe for shell eval.
// Any embedded single quote is escaped as `'\''`.
func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	// Fast path: no shell metacharacters, no whitespace → bare.
	needsQuote := false
	for _, r := range s {
		if r == ' ' || r == '\t' || r == '"' || r == '\'' || r == '$' ||
			r == '`' || r == '\\' || r == '|' || r == '&' || r == ';' ||
			r == '<' || r == '>' || r == '(' || r == ')' || r == '#' ||
			r == '*' || r == '?' || r == '[' || r == ']' || r == '{' ||
			r == '}' {
			needsQuote = true
			break
		}
	}
	if !needsQuote {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// sortStrings is a tiny wrapper we keep local to avoid importing "sort"
// twice (main.go, force.go, this file). Not performance-critical.
func sortStrings(xs []string) {
	// insertion sort; slices are tiny (<20 entries).
	for i := 1; i < len(xs); i++ {
		for j := i; j > 0 && xs[j-1] > xs[j]; j-- {
			xs[j-1], xs[j] = xs[j], xs[j-1]
		}
	}
}
