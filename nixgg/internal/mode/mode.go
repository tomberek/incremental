// Package mode decides whether a given shim invocation defers via a
// placeholder thunk or realises synchronously.
//
// Placeholder is the default and the only mode that keeps `nix build`
// out of the shim's hot path — every compile writes a .nix expression
// file and symlinks the output at it. A separate `nixgg force` at the
// end realises the whole DAG in one Nix invocation.
//
// Realise mode exists as a narrow carveout for cases where a downstream
// tool needs to run the just-produced artifact before make continues:
// autoconf conftests (`if ./conftest; then ... fi`) and cmake's
// try_compile probes are the canonical examples. In those cases the
// probe would see a .nix thunk file where it expected a runnable ELF.
package mode

import (
	"path/filepath"
	"strings"
)

// Mode is the result of the placeholder-vs-realise decision.
type Mode int

const (
	Placeholder Mode = iota
	Realise
)

// For returns the mode we should use for a given source or output path.
//
// If NIXGG_MODE=realise is set in the caller's env, everything realises
// (existing behavior; a few of the integration scripts depend on this).
// Otherwise the default is Placeholder, except:
//   - autoconf conftests (source or output starts with "conftest")
//   - cmake TryCompile scratch (path contains CMakeFiles/CMake{Scratch,Tmp})
//   - cmake compiler-detection files (test?Compiler…, CheckXXX…)
//
// The list mirrors what the bash mode_for() function returned; every
// pattern here was added because a real project tripped it.
func For(envMode string, path string) Mode {
	if envMode == "realise" {
		return Realise
	}
	base := filepath.Base(path)
	switch {
	case strings.HasPrefix(base, "conftest"):
		return Realise
	case matchCMakeProbe(base):
		return Realise
	case strings.Contains(path, "/CMakeFiles/CMakeScratch/") ||
		strings.Contains(path, "/CMakeFiles/CMakeTmp/"):
		return Realise
	}
	return Placeholder
}

func matchCMakeProbe(base string) bool {
	// e.g. testCCompiler.c, testCXXCompilerABI_C.cpp,
	//      CMakeCCompilerId.c, CMakeCXXCompilerABI_CXX.cpp
	if strings.HasPrefix(base, "test") && strings.Contains(base, "Compiler") {
		return true
	}
	if strings.HasPrefix(base, "CMake") && strings.Contains(base, "Compiler") {
		return true
	}
	// CheckFunctionExists, CheckIncludeFile, CheckCSourceCompiles, ...
	if strings.HasPrefix(base, "Check") &&
		(strings.Contains(base, "Exists") ||
			strings.Contains(base, "Include") ||
			strings.Contains(base, "SourceCompiles") ||
			strings.Contains(base, "SourceRuns") ||
			strings.Contains(base, "SymbolExists") ||
			strings.Contains(base, "TypeSize")) {
		return true
	}
	return false
}
