package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// cmdRun: `nixgg run [--mode ...] [--thunks-dir ...] -- <cmd> [args...]`
// Sets up the shim env (PATH, NIXGG_MODE, NIXGG_THUNKS_DIR) and execvs
// the given command. This is what a top-level script uses to wrap `make`.
func cmdRun(args []string) error {
	opts, cmd, err := parseRunLike(args)
	if err != nil {
		return err
	}
	// If NIXGG_MODE was already set in the parent env and the caller
	// didn't override with --mode, keep it. This lets a top-level
	// script wrap multiple `nixgg run --` under one placeholder scope.
	mode := opts.mode
	if !opts.modeSetByFlag {
		if parent := os.Getenv("NIXGG_MODE"); parent != "" {
			mode = parent
		}
	}
	// Pin thunks-dir once for the whole child tree, so recursive submakes
	// (deps/hiredis, deps/lua, …) don't scatter thunks across per-cwd
	// defaults. If the parent already set NIXGG_THUNKS_DIR, honor it;
	// otherwise default to $PWD/.nixgg/thunks *of the top-level invocation*.
	thunksDir := opts.thunksDir
	if thunksDir == "" {
		if inherited := os.Getenv("NIXGG_THUNKS_DIR"); inherited != "" {
			thunksDir = inherited
		} else {
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			thunksDir = filepath.Join(cwd, ".nixgg", "thunks")
		}
	}
	if err := setupShimEnv(mode, thunksDir); err != nil {
		return err
	}
	if len(cmd) == 0 {
		return fmt.Errorf("run: no command given (use '-- <cmd> [args…]')")
	}
	return execCmd(cmd)
}

// cmdEval: `nixgg eval -- <cmd>`. Same as `run --mode placeholder`.
func cmdEval(args []string) error {
	opts, cmd, err := parseRunLike(args)
	if err != nil {
		return err
	}
	_ = opts.mode // ignored; eval forces placeholder
	if err := setupShimEnv("placeholder", opts.thunksDir); err != nil {
		return err
	}
	if len(cmd) == 0 {
		return fmt.Errorf("eval: no command given (use '-- <cmd> [args…]')")
	}
	return execCmd(cmd)
}

type runOpts struct {
	mode          string
	modeSetByFlag bool
	thunksDir     string
}

// parseRunLike consumes flags shared by run/eval/build until the "--"
// terminator, then returns the remaining argv as the child command.
func parseRunLike(args []string) (opts runOpts, cmd []string, err error) {
	opts.mode = "realise"
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--mode":
			if i+1 >= len(args) {
				return opts, nil, fmt.Errorf("--mode requires an argument")
			}
			opts.mode = args[i+1]
			opts.modeSetByFlag = true
			i++
		case "--thunks-dir":
			if i+1 >= len(args) {
				return opts, nil, fmt.Errorf("--thunks-dir requires an argument")
			}
			abs, err := filepath.Abs(args[i+1])
			if err != nil {
				return opts, nil, err
			}
			opts.thunksDir = abs
			i++
		case "--":
			cmd = args[i+1:]
			return opts, cmd, nil
		default:
			return opts, nil, fmt.Errorf("unknown flag %q", a)
		}
	}
	return opts, nil, nil
}

// setupShimEnv sets the env vars that shims read: PATH prefix, mode,
// optional thunks dir. Does NOT bootstrap the toolchain — that's the
// caller's responsibility (via `nixgg env`).
func setupShimEnv(mode, thunksDir string) error {
	// Prepend our shims dir to PATH.
	root := os.Getenv("NIXGG_ROOT")
	if root == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		root = filepath.Dir(filepath.Dir(exe))
		if err := os.Setenv("NIXGG_ROOT", root); err != nil {
			return err
		}
	}
	shims := filepath.Join(root, "shims")
	newPath := shims + ":" + os.Getenv("PATH")
	if err := os.Setenv("PATH", newPath); err != nil {
		return err
	}
	if err := os.Setenv("CC", envDefault("CC", "cc")); err != nil {
		return err
	}
	if err := os.Setenv("CXX", envDefault("CXX", "c++")); err != nil {
		return err
	}
	if mode != "" {
		if err := os.Setenv("NIXGG_MODE", mode); err != nil {
			return err
		}
	}
	if thunksDir != "" {
		if err := os.Setenv("NIXGG_THUNKS_DIR", thunksDir); err != nil {
			return err
		}
	}
	return nil
}

// execCmd looks up cmd[0] on the (already updated) PATH and execvs it.
func execCmd(cmd []string) error {
	bin, err := findExec(cmd[0])
	if err != nil {
		return err
	}
	return syscall.Exec(bin, cmd, os.Environ())
}

func findExec(name string) (string, error) {
	if filepath.IsAbs(name) {
		return name, nil
	}
	// Explicit relative path (./configure, ../foo) → resolve against
	// cwd, not PATH. Matches shell behavior.
	if strings.ContainsRune(name, '/') {
		abs, err := filepath.Abs(name)
		if err != nil {
			return "", err
		}
		if info, err := os.Stat(abs); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return abs, nil
		}
		return "", fmt.Errorf("%s: not executable", name)
	}
	for _, d := range filepath.SplitList(os.Getenv("PATH")) {
		if d == "" {
			continue
		}
		p := filepath.Join(d, name)
		if info, err := os.Stat(p); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s: not found on PATH", name)
}

func envDefault(k, fallback string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return fallback
}
