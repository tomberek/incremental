// Package toolchain reads the NIXGG_* environment variables that identify
// the pinned toolchain (compiler, bash, coreutils, nix, helper store path).
//
// These are set once by the shell (via `nixgg env` or the flake's
// env-shell), then read by every shim invocation. A missing var is a hard
// error — we refuse to synthesize a compile expression with unresolved
// toolchain roots.
package toolchain

import (
	"fmt"
	"os"
)

// Config holds the pinned nixgg toolchain roots.
type Config struct {
	// Absolute path to the real cc (usually gcc-wrapper/bin/g++ from
	// the flake). We only use this to derive the bin/ dir; the actual
	// tool name that goes into the Nix expression is the caller's
	// argv[0] (cc, gcc, c++, g++), so that a `cc` shim doesn't turn
	// into a g++ compilation inside the sandbox.
	RealCC string

	// /nix/store/…-gcc-wrapper-… — the toolchain root as it appears
	// inside the sandbox. Nix imports need this as a string.
	CompilerRoot  string
	BashRoot      string
	CoreutilsRoot string

	// /nix/store/…-nixgg-nix — the realised nix/ helper package.
	// Every thunk imports its {builder,linker,archiver}.nix from here.
	Helpers string

	// The nix binary to invoke on force. Not needed by the shim path.
	Nix string

	// The alt store URL (`local?root=…` or `auto`). Passed via
	// NIX_CONFIG when we invoke `nix build`.
	Store string
}

// FromEnv reads the NIXGG_* variables. Returns an error listing every
// missing var, so the caller can print one clear diagnostic instead of
// hitting a series of ENV panics.
func FromEnv() (*Config, error) {
	c := &Config{
		RealCC:        os.Getenv("NIXGG_REAL_CC"),
		CompilerRoot:  os.Getenv("NIXGG_COMPILER_ROOT"),
		BashRoot:      os.Getenv("NIXGG_BASH_ROOT"),
		CoreutilsRoot: os.Getenv("NIXGG_COREUTILS_ROOT"),
		Helpers:       os.Getenv("NIXGG_NIX_HELPERS"),
		Nix:           os.Getenv("NIXGG_NIX"),
		Store:         os.Getenv("NIXGG_STORE"),
	}
	var missing []string
	if c.RealCC == "" {
		missing = append(missing, "NIXGG_REAL_CC")
	}
	if c.CompilerRoot == "" {
		missing = append(missing, "NIXGG_COMPILER_ROOT")
	}
	if c.BashRoot == "" {
		missing = append(missing, "NIXGG_BASH_ROOT")
	}
	if c.CoreutilsRoot == "" {
		missing = append(missing, "NIXGG_COREUTILS_ROOT")
	}
	if c.Helpers == "" {
		missing = append(missing, "NIXGG_NIX_HELPERS")
	}
	if c.Nix == "" {
		missing = append(missing, "NIXGG_NIX")
	}
	if c.Store == "" {
		missing = append(missing, "NIXGG_STORE")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("missing env: %v (run `nixgg env` to bootstrap)", missing)
	}
	return c, nil
}
