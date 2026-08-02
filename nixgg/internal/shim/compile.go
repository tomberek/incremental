// Package shim implements the shim entry points invoked when make (or
// any other build tool with our shims on PATH) executes cc/c++/ar.
//
// Every shim's job is: parse argv, build a Nix expression describing
// what should be produced, write that as a thunk, and symlink the
// output to the thunk. It never calls `nix build` (except for the
// autoconf-conftest carveout). All realisation happens later in
// `nixgg force`.
package shim

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/tbereknyei/nixgg/internal/dispatch"
	"github.com/tbereknyei/nixgg/internal/expr"
	"github.com/tbereknyei/nixgg/internal/mode"
	"github.com/tbereknyei/nixgg/internal/paths"
	"github.com/tbereknyei/nixgg/internal/scan"
	"github.com/tbereknyei/nixgg/internal/stage"
	"github.com/tbereknyei/nixgg/internal/storedeps"
	"github.com/tbereknyei/nixgg/internal/thunk"
	"github.com/tbereknyei/nixgg/internal/toolchain"
	"github.com/tbereknyei/nixgg/internal/wrapperenv"
)

// Compile is the shim entrypoint for `cc -c ...`. It parses argv,
// stages source + headers, writes a thunk, and symlinks the output.
//
// tool is the caller's argv[0] role (cc / gcc / c++ / g++) — that name
// is what gets baked into the derivation's toolBasename, so
// `cc -c foo.c` produces a "cc" invocation inside the sandbox, not g++.
func Compile(tool dispatch.Tool, args []string, cfg *toolchain.Config, l paths.Layout) error {
	source, output, flags, ok := parseCompileArgs(args)
	if !ok {
		// Not a single-TU compile; execv the real cc and hope.
		return Passthrough(cfg.RealCC, args)
	}

	// Fill in a default output name if -o was omitted.
	if output == "" {
		base := filepath.Base(source)
		if dot := strings.LastIndexByte(base, '.'); dot > 0 {
			base = base[:dot]
		}
		output = base + ".o"
	}

	logf("compile %s -> %s", source, output)

	// Resolve the real cc for scan-headers to match the caller's tool
	// role. Nix's gcc-wrapper sits at $compilerBin/{cc,gcc,c++,g++}
	// and picks up different defaults per name. Our shim's TOOL was
	// mapped from argv[0]; the sibling binary of the same name is what
	// scan-headers should use.
	compilerBin := filepath.Dir(cfg.RealCC)
	scannerCC := filepath.Join(compilerBin, tool.Basename())

	// 1. Discover headers.
	scanResult, err := scan.Run(l, scannerCC, source, flags)
	if err != nil {
		return err
	}

	// 2. Stage source + headers into .nixgg/srcs/<tu-id>/.
	srcAbs, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	// The source's staged relpath is its position under the project
	// root — the same layout every header uses. This matches the bash
	// driver: sources aren't special.
	srcRel, err := filepath.Rel(scanResult.ProjectRoot, srcAbs)
	if err != nil {
		return err
	}
	entries := make([]stage.Entry, 0, 1+len(scanResult.Headers))
	entries = append(entries, stage.Entry{Abs: srcAbs, Rel: srcRel})
	for _, h := range scanResult.Headers {
		entries = append(entries, stage.Entry{Abs: h.Abs, Rel: h.Rel})
	}
	tuID := stage.TUID(output)
	stageRes, err := stage.Sources(l, tuID, entries)
	if err != nil {
		return err
	}

	// 3. Assemble the sandbox flag list. Strip the caller's -I family
	// (both attached and separated forms) then re-add our staged -I
	// flags (relative to project root) and any store-prefixed -I flags
	// verbatim.
	sandboxFlags := rewriteFlags(flags, scanResult.StagedIFlags, scanResult.StoreIFlags)

	// 4. Build the expression.
	wrapperEnvJSON, err := wrapperenv.JSON()
	if err != nil {
		return err
	}
	storeDeps := storedeps.From(sandboxFlags, wrapperEnvJSON)

	// srcTree is a Nix path literal referring to the staging dir,
	// relative to the thunks dir (both live under .nixgg/).
	srcTreeLiteral := "../" + filepath.Base(l.Srcs) + "/" + tuID
	_ = stageRes // reuse info is informational only under the new design

	e := expr.Compile(expr.CompileParams{
		Helpers:        cfg.Helpers,
		Tool:           tool.Basename(),
		SrcTree:        srcTreeLiteral,
		Source:         srcRel,
		OutName:        filepath.Base(output),
		Flags:          sandboxFlags,
		StoreDepsJSON:  storedeps.AsJSONArray(storeDeps),
		WrapperEnvJSON: wrapperEnvJSON,
	})

	// 5. Dispatch on mode.
	if mode.For(os.Getenv("NIXGG_MODE"), source) == mode.Realise {
		return realiseAndLink(e, output, cfg, l)
	}

	id := thunk.Compute(e)
	thunkPath, err := thunk.Write(l, id, e)
	if err != nil {
		return err
	}
	if err := thunk.LinkPlaceholder(output, thunkPath); err != nil {
		return err
	}
	if err := thunk.RecordSymlink(l, id, output); err != nil {
		return err
	}
	logf("  thunk:      %s", thunkPath)
	return nil
}

// parseCompileArgs identifies the source + output + non-path flags.
// Returns ok=false if the invocation isn't a single-TU `-c` compile —
// in that case the caller passes through to the real cc.
func parseCompileArgs(args []string) (source, output string, flags []string, ok bool) {
	hasDashC := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-c":
			hasDashC = true
		case a == "-o":
			if i+1 >= len(args) {
				return "", "", nil, false
			}
			output = args[i+1]
			i++
		case strings.HasPrefix(a, "-o") && len(a) > 2:
			output = a[2:]
		case a == "-x" || a == "-Xlinker" || a == "-Xassembler":
			// Two-arg forms with values that aren't sources; keep both.
			if i+1 >= len(args) {
				return "", "", nil, false
			}
			flags = append(flags, a, args[i+1])
			i++
		case isSource(a):
			if source != "" {
				// Multiple sources — we don't model that in a single TU.
				return "", "", nil, false
			}
			source = a
		default:
			flags = append(flags, a)
		}
	}
	if !hasDashC || source == "" {
		return "", "", nil, false
	}
	return source, output, flags, true
}

// isSource returns true if a token looks like a source file that the
// driver would compile into a single .o. Matches the bash driver's
// extension set.
func isSource(a string) bool {
	switch strings.ToLower(filepath.Ext(a)) {
	case ".c", ".cc", ".cpp", ".cxx", ".s":
		return true
	}
	// Uppercase .C, .S are also sources (C++ / preprocessed asm) — keep
	// case-sensitive check for those.
	ext := filepath.Ext(a)
	if ext == ".C" || ext == ".S" {
		return true
	}
	return false
}

// rewriteFlags produces the sandbox-flag list. Strip -I/-isystem/etc
// pairs (both forms) since our staged -I flags cover the same
// directories in the sandbox's layout; then append staged + store.
func rewriteFlags(caller, staged, store []string) []string {
	pathFlags := map[string]bool{
		"-I": true, "-isystem": true, "-iquote": true,
		"-idirafter": true, "-include": true,
	}
	var out []string
	for i := 0; i < len(caller); i++ {
		a := caller[i]
		switch {
		case pathFlags[a]:
			if i+1 < len(caller) {
				i++
			}
			continue
		case strings.HasPrefix(a, "-I") && len(a) > 2:
			continue
		}
		out = append(out, a)
	}
	out = append(out, staged...)
	out = append(out, store...)
	return out
}

// realiseAndLink is the (rare) realise-mode carveout: build the thunk
// synchronously via `nix build --file <tmp>.nix` and re-target the
// output symlink. Used for autoconf conftests and cmake probes.
func realiseAndLink(exprBody, output string, cfg *toolchain.Config, l paths.Layout) error {
	// Write to a tempfile alongside the real thunks so relative-path
	// imports resolve. Reuse the id-based path to keep the file if the
	// same expression comes back later.
	id := thunk.Compute(exprBody)
	thunkPath, err := thunk.Write(l, id, exprBody)
	if err != nil {
		return err
	}
	built, err := nixBuildFile(cfg, thunkPath)
	if err != nil {
		return err
	}
	// Re-point output at /nix/store/... (via the alt-store's on-disk
	// prefix if present).
	src := altStoreOnDisk(cfg.Store, built) + "/" + filepath.Base(output)
	if _, err := os.Stat(src); err != nil {
		return fmt.Errorf("expected %s after build: %w", src, err)
	}
	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return err
	}
	_ = os.Remove(output)
	if err := os.Symlink(src, output); err != nil {
		return err
	}
	if err := thunk.RecordSymlink(l, id, output); err != nil {
		return err
	}
	logf("  built:      %s", built)
	return nil
}

func nixBuildFile(cfg *toolchain.Config, thunkPath string) (string, error) {
	cmd := exec.Command(cfg.Nix, "build", "-L", "--no-link", "--print-out-paths", "--file", thunkPath)
	cmd.Env = append(os.Environ(),
		"NIX_REMOTE=",
		"NIX_CONFIG=experimental-features = nix-command flakes ca-derivations\nstore = "+cfg.Store+"\n",
	)
	out, err := cmd.Output()
	if err != nil {
		var stderr string
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = string(ee.Stderr)
		}
		return "", fmt.Errorf("nix build --file %s: %w\n%s", thunkPath, err, stderr)
	}
	// Last non-empty line of stdout.
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if lines[i] != "" {
			return lines[i], nil
		}
	}
	return "", fmt.Errorf("nix build returned no output")
}

// altStoreOnDisk maps a canonical /nix/store/... path to its on-disk
// location under the alt store's root (e.g. /tmp/nixgg-store/nix/store/...).
// Returns the path unchanged for a system store.
func altStoreOnDisk(storeURL, canonical string) string {
	// storeURL looks like "local?root=/tmp/nixgg-store" for alt stores.
	const prefix = "local?root="
	if strings.HasPrefix(storeURL, prefix) {
		return strings.TrimPrefix(storeURL, prefix) + canonical
	}
	return canonical
}

// logf emits a one-line `[nixgg]` diagnostic on stderr. Kept minimal
// so we don't clutter build output. Callers pass a format string as
// they would to fmt.Fprintf.
func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[nixgg]   "+format+"\n", args...)
}
