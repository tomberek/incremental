// Package mode decides whether a given shim invocation defers via a
// placeholder thunk or realises synchronously.
//
// Placeholder is the default: every compile writes a .nix expression
// file and symlinks the output at it. The link shim's inline realise
// hook (NIXGG_AUTOFORCE=1) or an explicit `nixgg force` materialises
// the whole DAG in one Nix invocation at the end.
//
// Realise mode is a narrow carveout for cases where a downstream tool
// needs to run the just-produced artifact before make continues:
// autoconf conftests (`if ./conftest; then ... fi`) and cmake's
// try_compile probes are the canonical examples. In those cases the
// probe would see a .nix thunk file where it expected a runnable ELF.
// The decision is made per-TU by filename pattern — the outer build
// doesn't need to know or care.
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

// For returns the mode for a given source or output path.
//
// Placeholder unless the path matches a known conftest/probe pattern:
//   - autoconf conftests (basename starts with "conftest")
//   - cmake compiler-detection files (test?Compiler…, CheckXXX…)
//   - cmake TryCompile scratch (path contains CMakeFiles/CMake{Scratch,Tmp})
//
// Every pattern here was added because a real project tripped it.
func For(path string) Mode {
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
