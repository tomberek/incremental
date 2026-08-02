// Package dispatch handles the busybox-style multi-call binary
// dispatch: given argv, decide which shim behavior (compile, link,
// archive, ranlib, passthrough) to run. Also expands @rspfile args
// in-place — some build systems (ninja) hand the compiler an
// @path/to/rspfile pointing at a text file listing the real argv;
// downstream shim logic needs to see the flattened form.
package dispatch

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// Tool is the classified role that a shim should play.
type Tool int

const (
	ToolUnknown Tool = iota
	ToolCC
	ToolGCC
	ToolCXX
	ToolGXX
	ToolAR
	ToolRanlib
)

// Basename returns the argv[0] name we advertise to the sandbox.
// Nix's gcc-wrapper dispatches by the invocation name so `cc` and
// `g++` behave differently for the same underlying binary.
func (t Tool) Basename() string {
	switch t {
	case ToolCC:
		return "cc"
	case ToolGCC:
		return "gcc"
	case ToolCXX:
		return "c++"
	case ToolGXX:
		return "g++"
	case ToolAR:
		return "ar"
	case ToolRanlib:
		return "ranlib"
	}
	return ""
}

// FromArgv0 classifies argv[0] (usually a symlink name like "cc"). We
// look at the file basename, not the target of the symlink.
func FromArgv0(argv0 string) Tool {
	base := filepath.Base(argv0)
	switch base {
	case "cc":
		return ToolCC
	case "gcc":
		return ToolGCC
	case "c++":
		return ToolCXX
	case "g++":
		return ToolGXX
	case "ar":
		return ToolAR
	case "ranlib":
		return ToolRanlib
	}
	return ToolUnknown
}

// Action is what a compiler-family shim decides to do based on argv.
type Action int

const (
	ActionCompile Action = iota // has -c
	ActionLink                  // no -c, produces an executable/shared lib
)

// IsCompile returns true iff argv contains -c (or -E/-S which we treat
// as passthrough, but the shim never gets called for those in practice
// since they're rare and we can leave passthrough logic to each driver).
func IsCompile(argv []string) bool {
	for _, a := range argv {
		if a == "-c" {
			return true
		}
	}
	return false
}

// ExpandRspfiles walks argv and replaces any @rspfile entries with the
// contents of the referenced file. Quoted args are unquoted; whitespace
// is used as the separator. Returns a fresh slice.
//
// If no @-file is present the input is returned unchanged (no copy).
func ExpandRspfiles(argv []string) []string {
	// Fast path: no @-arg → no allocation.
	hasRsp := false
	for _, a := range argv {
		if len(a) > 1 && a[0] == '@' {
			// Verify it's a real file — plenty of legitimate flags start
			// with @ (e.g. some assembler features). @filename is only
			// meaningful if the file exists.
			if _, err := os.Stat(a[1:]); err == nil {
				hasRsp = true
				break
			}
		}
	}
	if !hasRsp {
		return argv
	}
	out := make([]string, 0, len(argv))
	for _, a := range argv {
		if len(a) > 1 && a[0] == '@' {
			if body, err := readRspfile(a[1:]); err == nil {
				out = append(out, body...)
				continue
			}
		}
		out = append(out, a)
	}
	return out
}

func readRspfile(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for sc.Scan() {
		for _, tok := range strings.Fields(sc.Text()) {
			out = append(out, unquote(tok))
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// unquote trims a single layer of matched surrounding quotes. Rspfiles
// are typically shell-tokenized already; ninja quotes strings that
// contain spaces. We handle both "..." and '...'.
func unquote(s string) string {
	if len(s) < 2 {
		return s
	}
	if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
		return s[1 : len(s)-1]
	}
	return s
}
