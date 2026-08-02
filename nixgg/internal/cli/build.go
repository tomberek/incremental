package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// cmdBuild: `nixgg build --target FILE [--target ...] [--thunks-dir DIR] -- <cmd>`
//
// Eval + force in one shot. Runs the given command under placeholder
// mode; when it exits successfully, walks the DAG for each --target
// and realises via a single `nix build`.
func cmdBuild(args []string) error {
	var (
		thunksDir string
		targets   []string
	)
	// Parse flags until "--".
	i := 0
	for ; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--target":
			if i+1 >= len(args) {
				return fmt.Errorf("--target requires an argument")
			}
			targets = append(targets, args[i+1])
			i++
		case "--thunks-dir":
			if i+1 >= len(args) {
				return fmt.Errorf("--thunks-dir requires an argument")
			}
			thunksDir = args[i+1]
			i++
		case "--":
			i++
			goto done
		default:
			return fmt.Errorf("unknown flag %q (use -- to separate command)", a)
		}
	}
done:
	cmd := args[i:]
	if len(targets) == 0 {
		return fmt.Errorf("build: at least one --target is required")
	}
	if len(cmd) == 0 {
		return fmt.Errorf("build: no command (use '-- <cmd> [args…]')")
	}

	// Default thunks-dir precedence:
	//   1. --thunks-dir on the CLI
	//   2. $NIXGG_THUNKS_DIR from the parent env (so a top-level script
	//      can pin one dir for src + deps subdirs alike)
	//   3. $PWD/.nixgg/thunks
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
	abs, err := filepath.Abs(thunksDir)
	if err != nil {
		return err
	}
	if err := setupShimEnv("placeholder", abs); err != nil {
		return err
	}

	// Run the eval phase as a child (so we can see its exit code
	// without exec-replacing ourselves).
	fmt.Fprintf(os.Stderr, "[nixgg build] eval: %s\n", strings.Join(cmd, " "))
	bin, err := findExec(cmd[0])
	if err != nil {
		return err
	}
	child := exec.Command(bin, cmd[1:]...)
	child.Stdin, child.Stdout, child.Stderr = os.Stdin, os.Stdout, os.Stderr
	// An eval-phase non-zero exit isn't fatal by itself. Redis's
	// tests/modules subtree fails during eval for reasons unrelated to
	// the target we're actually building; the correct signal is
	// whether force can realise the target below. Log the exit code
	// and continue to force.
	if err := child.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "[nixgg build] eval exited non-zero (%v); continuing to force\n", err)
	}

	// Force phase: realise all targets.
	fmt.Fprintf(os.Stderr, "[nixgg build] force: %s\n", strings.Join(targets, " "))
	return cmdForce(targets)
}
