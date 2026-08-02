package shim

import (
	"os"
	"syscall"
)

// Passthrough replaces the current process image with the real tool.
// This is the right thing for shims that decide not to model a call:
// we don't pay for a fork, stdin/stdout/stderr are already correct,
// and the caller sees the tool's true exit code.
func Passthrough(realTool string, args []string) error {
	argv := append([]string{realTool}, args...)
	return syscall.Exec(realTool, argv, os.Environ())
}
