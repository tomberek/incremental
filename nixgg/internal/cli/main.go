// Package cli implements the nixgg CLI. It's invoked when the binary
// is called as "nixgg" (or via `nix run .#nixgg -- run ...`), not
// through a shim symlink.
package cli

import (
	"fmt"
	"os"
)

// Main is the CLI entrypoint. args excludes argv[0].
func Main(args []string) error {
	if len(args) == 0 {
		usage()
		return fmt.Errorf("missing subcommand")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "run":
		return cmdRun(rest)
	case "eval":
		return cmdEval(rest)
	case "force":
		return cmdForce(rest)
	case "build":
		return cmdBuild(rest)
	case "env":
		return cmdEnv(rest)
	case "-h", "--help", "help":
		usage()
		return nil
	}
	usage()
	return fmt.Errorf("unknown subcommand %q", sub)
}

func usage() {
	fmt.Fprint(os.Stderr, `usage: nixgg <subcommand> [args…]

  run     [--mode realise|placeholder] [--thunks-dir DIR] -- <cmd…>
  eval    [--thunks-dir DIR] -- <cmd…>
  force   [--thunks-dir DIR] [--roots] [target…]
  build   --target FILE [--target FILE…] [--thunks-dir DIR] -- <cmd…>
  env     [--store URL] [--print-only]
`)
}
