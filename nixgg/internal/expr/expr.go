// Package expr builds the Nix expression string that a shim writes to
// .nixgg/thunks/<id>.nix. Every expression is one `import <helper>
// { ... }` call — the helper (builder.nix / linker.nix / archiver.nix)
// lives in the realised nix/ package alongside toolchain.nix which
// supplies the pinned compiler/bash/coreutils store paths.
//
// The expression body is byte-deterministic: same inputs → same string
// → same thunk id. That's what makes idempotent Write and Nix's own
// eval cache work.
package expr

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// Compile builds a per-TU compile expression.
func Compile(p CompileParams) string {
	var b strings.Builder
	fmt.Fprintf(&b, "import %s/builder.nix {\n", p.Helpers)
	fmt.Fprintf(&b, "  toolBasename   = %q;\n", p.Tool)
	fmt.Fprintf(&b, "  srcTree        = %s;\n", p.SrcTree) // Nix path literal, unquoted
	fmt.Fprintf(&b, "  source         = %q;\n", p.Source)
	fmt.Fprintf(&b, "  outName        = %q;\n", p.OutName)
	fmt.Fprintf(&b, "  flagsJSON      = ''%s'';\n", jsonArrayIndented(p.Flags))
	fmt.Fprintf(&b, "  storeDepsJSON  = ''%s'';\n", p.StoreDepsJSON)
	fmt.Fprintf(&b, "  wrapperEnvJSON = ''%s'';\n", p.WrapperEnvJSON)
	b.WriteString("}\n")
	return b.String()
}

// CompileParams is the input for one compile expression.
type CompileParams struct {
	Helpers        string   // /nix/store/…-nixgg-nix
	Tool           string   // "cc", "gcc", "c++", "g++"
	SrcTree        string   // Nix path literal, e.g. "../srcs/foo"
	Source         string   // relative path inside srcTree, e.g. "src/foo.c"
	OutName        string   // "foo.o"
	Flags          []string // sandbox-relative flags
	StoreDepsJSON  string   // pre-encoded JSON array
	WrapperEnvJSON string   // pre-encoded JSON object
}

// Link builds a link expression.
func Link(p LinkParams) string {
	var b strings.Builder
	fmt.Fprintf(&b, "import %s/linker.nix {\n", p.Helpers)
	fmt.Fprintf(&b, "  toolBasename   = %q;\n", p.Tool)
	fmt.Fprintf(&b, "  outName        = %q;\n", p.OutName)
	fmt.Fprintf(&b, "  inputs         = %s;\n", InputsList(p.Inputs))
	fmt.Fprintf(&b, "  flagsJSON      = ''%s'';\n", jsonArrayIndented(p.Flags))
	fmt.Fprintf(&b, "  storeDepsJSON  = ''%s'';\n", p.StoreDepsJSON)
	fmt.Fprintf(&b, "  wrapperEnvJSON = ''%s'';\n", p.WrapperEnvJSON)
	b.WriteString("}\n")
	return b.String()
}

// LinkParams is the input for one link expression.
type LinkParams struct {
	Helpers        string
	Tool           string
	OutName        string
	Inputs         []Input
	Flags          []string
	StoreDepsJSON  string
	WrapperEnvJSON string
}

// Archive builds an `ar` expression.
func Archive(p ArchiveParams) string {
	var b strings.Builder
	fmt.Fprintf(&b, "import %s/archiver.nix {\n", p.Helpers)
	fmt.Fprintf(&b, "  outName        = %q;\n", p.OutName)
	fmt.Fprintf(&b, "  inputs         = %s;\n", InputsList(p.Inputs))
	fmt.Fprintf(&b, "  arFlags        = %q;\n", p.ARFlags)
	fmt.Fprintf(&b, "  storeDepsJSON  = ''%s'';\n", p.StoreDepsJSON)
	fmt.Fprintf(&b, "  wrapperEnvJSON = ''%s'';\n", p.WrapperEnvJSON)
	b.WriteString("}\n")
	return b.String()
}

// ArchiveParams is the input for one archive expression.
type ArchiveParams struct {
	Helpers        string
	OutName        string
	Inputs         []Input
	ARFlags        string
	StoreDepsJSON  string
	WrapperEnvJSON string
}

// Input describes one linker/archiver input.
type Input struct {
	// Kind is "store" for realised inputs (rendered as builtins.storePath)
	// or "nix" for unrealised sibling thunks (rendered as an `import`).
	Kind string
	// Ref is either a /nix/store/… root (Kind=store) or an absolute
	// path to a sibling thunk .nix file (Kind=nix). We render "nix"
	// refs as `import ./<basename>` so the thunk file's byte-content
	// stays cwd-independent.
	Ref string
	// Name is the basename that will appear inside the derivation
	// output — same as the caller-visible symlink's basename.
	Name string
}

// InputsList renders `inputs = [ ... ];` value for a linker/archiver
// expression. Each entry is `{ drv = <expr>; name = "<n>"; }`.
func InputsList(inputs []Input) string {
	if len(inputs) == 0 {
		return "[ ]"
	}
	var b strings.Builder
	b.WriteString("[ ")
	for _, in := range inputs {
		var drv string
		switch in.Kind {
		case "store":
			drv = fmt.Sprintf("builtins.storePath %q", in.Ref)
		case "nix":
			// Relativize: sibling thunks live in the same dir as this
			// thunk, so `import ./<id>.nix` resolves correctly and the
			// content is cwd-independent.
			base := in.Ref
			if i := strings.LastIndexByte(base, '/'); i >= 0 {
				base = base[i+1:]
			}
			drv = "import ./" + base
		default:
			// Shouldn't happen; be visible if it does.
			drv = fmt.Sprintf("/* unknown ref_kind: %s */ null", in.Kind)
		}
		fmt.Fprintf(&b, "{ drv = %s; name = %q; } ", drv, in.Name)
	}
	b.WriteString("]")
	return b.String()
}

// jsonArrayIndented renders a []string as a pretty JSON array. This is
// what the bash driver used to embed inside a ''...'' Nix string. The
// indentation matches so thunk IDs are stable across the rewrite.
func jsonArrayIndented(items []string) string {
	if len(items) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteString("[")
	for i, s := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString("\n  ")
		enc, _ := json.Marshal(s)
		b.Write(enc)
	}
	b.WriteString("\n]")
	return b.String()
}

// SortedFlags is a defensive helper — some call sites want stable
// ordering even when the caller passed flags in an incidental order.
// Compile flags are typically order-sensitive so we don't use this
// there; it's a utility for tests.
func SortedFlags(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}
