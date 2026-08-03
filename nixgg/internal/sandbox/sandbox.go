// Package sandbox holds sandbox-mode helpers: submitting JSON drvs to
// the outer nix daemon via `nix derivation add`, looking up drv paths
// for previously-produced outputs.
//
// This mode is selected by NIXGG_SANDBOX=1 and is only meaningful
// when nixgg is running inside a builder-rpc-v0 derivation (see
// nixgg/dyn-drv/NOTES.md).
package sandbox

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/tbereknyei/nixgg/internal/expr"
	"github.com/tbereknyei/nixgg/internal/toolchain"
)

// Enabled reports whether NIXGG_SANDBOX=1 is set.
func Enabled() bool {
	return os.Getenv("NIXGG_SANDBOX") == "1"
}

// DerivationAdd pipes a JSON drv description to `nix derivation add`
// and returns the resulting drv store path. Works both inside a
// builder-rpc-v0 sandbox (via $NIX_REMOTE) and outside (regular
// daemon).
func DerivationAdd(cfg *toolchain.Config, drv expr.JSONDrv) (string, error) {
	body, err := json.Marshal(drv)
	if err != nil {
		return "", fmt.Errorf("encode drv json: %w", err)
	}
	cmd := exec.Command(cfg.Nix, "derivation", "add")
	cmd.Env = os.Environ()
	cmd.Stdin = bytes.NewReader(body)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("nix derivation add %s: %w\n%s", drv.Name, err, stderr.String())
	}
	path := strings.TrimSpace(string(out))
	if path == "" {
		return "", fmt.Errorf("nix derivation add: empty output")
	}
	return path, nil
}

// StoreAddScan uploads a directory via `nix store add --scan -n name
// path` and returns the resulting store path. --scan makes the
// daemon scan the tree for references to already-present store
// objects and record them — required inside a sandbox where
// unregistered references cause build-time errors.
func StoreAddScan(cfg *toolchain.Config, name, path string) (string, error) {
	cmd := exec.Command(cfg.Nix, "store", "add", "--scan", "-n", name, path)
	cmd.Env = os.Environ()
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("nix store add %s: %w\n%s", path, err, stderr.String())
	}
	sp := strings.TrimSpace(string(out))
	if sp == "" {
		return "", fmt.Errorf("nix store add: empty output")
	}
	return sp, nil
}

// SubmitOutput registers `drvPath` (a `.drv` store path we produced
// via DerivationAdd) as the currently-running outer derivation's
// named output. Only valid inside a builder-rpc-v0 sandbox.
func SubmitOutput(cfg *toolchain.Config, drvPath, outputName string) error {
	cmd := exec.Command(cfg.Nix, "store", "submit-output", drvPath, outputName)
	cmd.Env = os.Environ()
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("nix store submit-output %s %s: %w", drvPath, outputName, err)
	}
	return nil
}

// PointOutputAtDrv creates a symlink at `output` pointing at the drv
// store path. The symlink acts as the sandbox-mode analogue of the
// .nix-thunk symlink: it records "this output was produced by this
// drv" in a way downstream shims can pick up.
//
// Also writes `<output>.name` — the basename inside the drv's output
// dir that a subsequent link shim needs to reference (e.g. "hello.o"
// so `${drv}/hello.o` builds correctly).
func PointOutputAtDrv(output, drvPath string) error {
	if err := os.MkdirAll(filepath.Dir(output), 0o755); err != nil {
		return err
	}
	_ = os.Remove(output)
	if err := os.Symlink(drvPath, output); err != nil {
		return fmt.Errorf("symlink %s -> %s: %w", output, drvPath, err)
	}
	return nil
}
