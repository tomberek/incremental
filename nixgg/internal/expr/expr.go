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
	"crypto/sha256"
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
	// path to a sibling thunk .nix file (Kind=nix). Absolute paths let
	// the thunk file survive `cp`: Makefile steps that copy a thunk
	// symlink to a peer location (e.g. `cp obj/foo.o dest/foo.o`)
	// dereference the symlink and produce a regular file with the same
	// bytes. Absolute imports still resolve; relative ones wouldn't.
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
			// Absolute Nix path literal (unquoted): survives `cp` of the
			// containing thunk to a peer directory. See Input.Ref docstring.
			drv = "import " + in.Ref
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

// ---------------------------------------------------------------------
// JSON-drv emission (sandbox / dyn-drv mode)
//
// These are byte-for-byte-different serialisations of the same shim
// intent, targeting `nix derivation add` (which reads JSON on stdin)
// rather than a `.nix` text file. Used when NIXGG_SANDBOX=1 — the
// outer mkNixggBuild derivation runs the shims inside a builder-rpc-v0
// sandbox where the only permitted store ops are add / text-add /
// submit-output.
//
// The JSON we emit follows the format Nix's `derivation add` accepts,
// which is *not* the same shape as the JSON `nix derivation show`
// prints. Notably:
//
//   - `inputs.srcs` is an array of BASENAMES (hash+name), not full
//     /nix/store/... paths. Full paths trigger "illegal base-32
//     character '/'" at parse time.
//   - `env.out` must be the placeholder string returned by
//     `builtins.placeholder "out"` for this specific derivation.
//   - `inputs.drvs` maps a full drv store path to `{ outputs = […]; }`
//     — those are the drv-references we get back from previous
//     `nix derivation add` calls.
//
// See nixgg/dyn-drv/NOTES.md for the exploration that established
// this schema.

// JSONDrv is the JSON shape `nix derivation add` accepts. Fields
// mirror the Nix internal derivation type; we assemble it in-Go and
// let json.Marshal handle the wire encoding.
type JSONDrv struct {
	Name    string             `json:"name"`
	System  string             `json:"system"`
	Builder string             `json:"builder"`
	Args    []string           `json:"args"`
	Env     map[string]string  `json:"env"`
	Inputs  JSONDrvInputs      `json:"inputs"`
	Outputs map[string]JSONOut `json:"outputs"`
	Version int                `json:"version"`
}

// JSONDrvInputs holds the two input slots Nix distinguishes.
type JSONDrvInputs struct {
	// Drvs maps a drv store path (full /nix/store/…-…drv path) to the
	// set of outputs of that drv we depend on.
	Drvs map[string]JSONDrvRef `json:"drvs"`
	// Srcs is a list of already-realised store objects the sandbox
	// needs mounted. BASENAMES ONLY (see file docstring above).
	Srcs []string `json:"srcs"`
}

// JSONDrvRef is the value side of an inputs.drvs entry. Nix's
// derivation-JSON parser requires `dynamicOutputs` to be present
// (empty is fine); the `omitempty` tag would drop the key when the
// map is nil and trigger "Expected JSON object to contain key
// 'dynamicOutputs' but it doesn't".
type JSONDrvRef struct {
	Outputs        []string       `json:"outputs"`
	DynamicOutputs map[string]any `json:"dynamicOutputs"`
}

// JSONOut describes an output of the derivation.
type JSONOut struct {
	Method   string `json:"method"`   // "nar" for a directory, "flat" for a single file
	HashAlgo string `json:"hashAlgo"` // "sha256"
}

// CompileJSONParams is the sandbox-mode analog of CompileParams.
// SrcTree is a store-path basename (e.g. "abc123-src-foo") — the
// caller has already `nix store add`ed the staged src tree and put
// it in Inputs.Srcs.
type CompileJSONParams struct {
	Name        string            // derivation name, e.g. "tu-foo.o" — no .drv suffix
	OutName     string            // "foo.o"; the builder writes to $out/<outName>
	System      string            // "x86_64-linux"
	Bash        string            // full /nix/store/... path to bash (for builder)
	Coreutils   string            // full /nix/store/... path to coreutils (added to PATH)
	Compiler    string            // full /nix/store/... path to gcc-wrapper (added to PATH)
	Tool        string            // "cc", "g++", etc.
	SrcStore    string            // full /nix/store/... path to the staged src tree
	Source      string            // relative path inside SrcStore, e.g. "src/foo.c"
	Flags       []string          // compile flags
	Placeholder string            // builtins.placeholder "out" for this drv
	Srcs        []string          // basenames for inputs.srcs — bash, coreutils, compiler, srcStore
	Env         map[string]string // extra env (NIX_CFLAGS_COMPILE etc.); merged over defaults
}

// CompileJSON produces a JSONDrv equivalent to the .nix expression
// that builder.nix would generate for the same inputs. The shell
// script is baked directly into args[1] rather than delegated to
// builder.nix — the sandbox doesn't have eval, so we can't `import`
// a helper.
func CompileJSON(p CompileJSONParams) JSONDrv {
	env := map[string]string{
		"out":    p.Placeholder,
		"name":   p.Name,
		"system": p.System,
	}
	for k, v := range p.Env {
		env[k] = v
	}
	script := fmt.Sprintf(
		`set -euo pipefail
export PATH="%s/bin:%s/bin"
mkdir -p "$out"
cd "%s"
"%s" %s -c "%s" -o "$out/%s"
`,
		p.Coreutils, p.Compiler,
		p.SrcStore,
		p.Tool, shellQuoteFlags(p.Flags), p.Source, p.OutName,
	)
	return JSONDrv{
		Name:    p.Name,
		System:  p.System,
		Builder: p.Bash + "/bin/bash",
		Args:    []string{"-c", script},
		Env:     env,
		Inputs: JSONDrvInputs{
			Drvs: map[string]JSONDrvRef{},
			Srcs: p.Srcs,
		},
		Outputs: map[string]JSONOut{
			"out": {Method: "nar", HashAlgo: "sha256"},
		},
		Version: 4,
	}
}

// LinkJSONParams is the sandbox-mode analog of LinkParams. Inputs
// coming from prior shim calls have Kind="drv" and Ref=<drv-path>.
// Inputs coming from already-realised store paths (e.g. system libs
// referenced via -I on a compile) have Kind="src" and Ref=<basename>.
type LinkJSONParams struct {
	Name        string
	OutName     string
	System      string
	Bash        string
	Coreutils   string
	Compiler    string
	Tool        string
	Inputs      []JSONDrvInput // per-input drv or store-path reference
	Flags       []string
	Placeholder string
	ExtraSrcs   []string          // additional basenames for inputs.srcs (bash, coreutils, compiler)
	Env         map[string]string // wrapper env
}

// JSONDrvInput is one entry in a linker/archiver's input list. Either
// references a drv (whose "out" we'll dereference at build time via a
// placeholder) or a real store path we already have (basename in
// inputs.srcs, path fragment in args).
type JSONDrvInput struct {
	// Kind = "drv" or "src". "drv" means Ref is a full drv store path
	// (/nix/store/…-….drv) and Name is the file inside that drv's out
	// dir. "src" means Ref is a store-path basename (goes in srcs) and
	// Name is the file inside that store path.
	Kind string
	Ref  string
	Name string
}

// ArchiveJSONParams is the sandbox-mode analog of ArchiveParams.
type ArchiveJSONParams struct {
	Name        string
	OutName     string
	System      string
	Bash        string
	Coreutils   string
	AR          string // full /nix/store/... path to gnu binutils (for `ar`)
	ARFlags     string // e.g. "rcs"
	Inputs      []JSONDrvInput
	Placeholder string
	ExtraSrcs   []string
	Env         map[string]string
}

// ArchiveJSON produces a JSONDrv for an ar step.
func ArchiveJSON(p ArchiveJSONParams) JSONDrv {
	env := map[string]string{
		"out":    p.Placeholder,
		"name":   p.Name,
		"system": p.System,
	}
	for k, v := range p.Env {
		env[k] = v
	}
	drvs := map[string]JSONDrvRef{}
	srcs := append([]string{}, p.ExtraSrcs...)
	seen := map[string]bool{}
	for _, s := range srcs {
		seen[s] = true
	}
	inputRefs := make([]string, 0, len(p.Inputs))
	for _, in := range p.Inputs {
		switch in.Kind {
		case "drv":
			ref := drvs[in.Ref]
			ref.Outputs = appendUnique(ref.Outputs, "out")
			if ref.DynamicOutputs == nil {
				ref.DynamicOutputs = map[string]any{}
			}
			drvs[in.Ref] = ref
			ph := caOutputPlaceholder(in.Ref, "out")
			inputRefs = append(inputRefs, fmt.Sprintf("'%s/%s'", ph, in.Name))
		case "src":
			if !seen[in.Ref] {
				srcs = append(srcs, in.Ref)
				seen[in.Ref] = true
			}
			inputRefs = append(inputRefs, fmt.Sprintf("'/nix/store/%s/%s'", in.Ref, in.Name))
		}
	}
	script := fmt.Sprintf(
		`set -euo pipefail
export PATH="%s/bin:%s/bin"
mkdir -p "$out"
"%s/bin/ar" '%s' "$out/%s" %s
`,
		p.Coreutils, p.AR,
		p.AR, p.ARFlags, p.OutName,
		strings.Join(inputRefs, " "),
	)
	return JSONDrv{
		Name:    p.Name,
		System:  p.System,
		Builder: p.Bash + "/bin/bash",
		Args:    []string{"-c", script},
		Env:     env,
		Inputs: JSONDrvInputs{
			Drvs: drvs,
			Srcs: srcs,
		},
		Outputs: map[string]JSONOut{
			"out": {Method: "nar", HashAlgo: "sha256"},
		},
		Version: 4,
	}
}

// LinkJSON produces a JSONDrv for a link step.
func LinkJSON(p LinkJSONParams) JSONDrv {
	env := map[string]string{
		"out":    p.Placeholder,
		"name":   p.Name,
		"system": p.System,
	}
	for k, v := range p.Env {
		env[k] = v
	}

	drvs := map[string]JSONDrvRef{}
	srcs := append([]string{}, p.ExtraSrcs...)
	seenSrc := map[string]bool{}
	for _, s := range srcs {
		seenSrc[s] = true
	}
	inputRefs := make([]string, 0, len(p.Inputs))
	for _, in := range p.Inputs {
		switch in.Kind {
		case "drv":
			// The map key must be a basename (hash+name+.drv), not the
			// full /nix/store/... path — `nix derivation add` rejects
			// the leading slash as "illegal base-32 character '/'".
			// Same rule as inputs.srcs.
			refKey := in.Ref
			if i := strings.LastIndexByte(refKey, '/'); i >= 0 {
				refKey = refKey[i+1:]
			}
			ref := drvs[refKey]
			ref.Outputs = appendUnique(ref.Outputs, "out")
			if ref.DynamicOutputs == nil {
				ref.DynamicOutputs = map[string]any{}
			}
			drvs[refKey] = ref
			// Reference in shell: use the ca-derivation placeholder for
			// this drv's "out". The placeholder gets substituted with a
			// real /nix/store/… path at build time. caOutputPlaceholder
			// still needs the full path so it can compute a hashPart.
			ph := caOutputPlaceholder(in.Ref, "out")
			inputRefs = append(inputRefs, fmt.Sprintf("'%s/%s'", ph, in.Name))
		case "src":
			if !seenSrc[in.Ref] {
				srcs = append(srcs, in.Ref)
				seenSrc[in.Ref] = true
			}
			// storeBase looks like "abc123-name"; the full path
			// interpolates from the sandbox mount.
			inputRefs = append(inputRefs, fmt.Sprintf("'/nix/store/%s/%s'", in.Ref, in.Name))
		default:
			inputRefs = append(inputRefs, fmt.Sprintf("'/* unknown ref kind: %s */'", in.Kind))
		}
	}
	script := fmt.Sprintf(
		`set -euo pipefail
export PATH="%s/bin:%s/bin"
mkdir -p "$out"
"%s" %s %s -o "$out/%s"
`,
		p.Coreutils, p.Compiler,
		p.Tool,
		shellQuoteFlags(p.Flags),
		strings.Join(inputRefs, " "),
		p.OutName,
	)
	return JSONDrv{
		Name:    p.Name,
		System:  p.System,
		Builder: p.Bash + "/bin/bash",
		Args:    []string{"-c", script},
		Env:     env,
		Inputs: JSONDrvInputs{
			Drvs: drvs,
			Srcs: srcs,
		},
		Outputs: map[string]JSONOut{
			"out": {Method: "nar", HashAlgo: "sha256"},
		},
		Version: 4,
	}
}

// caOutputPlaceholder returns the `/<nix32-hash>` downstream
// placeholder for a specific output of a CA derivation. Nix
// substitutes this string with the resolved store path at build
// time. The formula (mirrored from NixOS/nix
// src/libstore/downstream-placeholder.cc:unknownCaOutput):
//
//	drvName    = drvBasename with trailing ".drv" stripped
//	pathName   = drvName + (outputName == "out" ? "" : "-" + outputName)
//	clearText  = "nix-upstream-output:" + drvHashPart + ":" + pathName
//	digest     = sha256(clearText)
//	rendered   = "/" + nix32(digest)
//
// drvPath is expected to be a full store path — /nix/store/<hash>-<name>.drv.
func caOutputPlaceholder(drvPath, output string) string {
	base := drvPath
	if i := strings.LastIndexByte(base, '/'); i >= 0 {
		base = base[i+1:]
	}
	// A store-path basename is "<32-char-hash>-<name>".
	// storeHashLen = 32 chars (Nix32 encoding of 160-bit compressed hash).
	if len(base) <= storeHashLen+1 {
		return "/INVALID_DRV_PATH_" + base
	}
	hashPart := base[:storeHashLen]
	drvName := base[storeHashLen+1:]
	drvName = strings.TrimSuffix(drvName, ".drv")

	pathName := drvName
	if output != "out" {
		pathName = drvName + "-" + output
	}
	clearText := "nix-upstream-output:" + hashPart + ":" + pathName
	digest := sha256.Sum256([]byte(clearText))
	return "/" + nix32Encode(digest[:])
}

// storeHashLen is the number of Nix32 characters in the hash prefix
// of a store-path basename. Nix's internal constant is `HashLen = 32`.
const storeHashLen = 32

// OutPlaceholderNix32 is the Nix32-encoded sha256 of "nix-output:out"
// — the string Nix substitutes for a placeholder-`$out` reference at
// build time. Since every derivation with a single "out" output
// uses the same placeholder, we hardcode it. Verified:
//
//	nix eval --raw --expr 'builtins.placeholder "out"'
//	=> /1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9
//
// (The leading '/' is the placeholder prefix; drop it if you need
// the bare digest.)
const OutPlaceholderNix32 = "1rz4g4znpzjwh1xymhjpm42vipw92pr73vdgl6xs1hycac8kf2n9"

// nix32Chars is the alphabet used by Nix's base32 encoding. Copied
// verbatim from NixOS/nix src/libutil/include/nix/util/base-nix-32.hh
// — "omitted: E O U T" (and case-folded).
const nix32Chars = "0123456789abcdfghijklmnpqrsvwxyz"

// nix32Encode encodes bytes into Nix's flavour of base32. Iterates
// characters back-to-front, taking 5 bits at a time from a virtual
// bit-shifted view of the input. Mirrors BaseNix32::encode in
// src/libutil/base-nix-32.cc.
func nix32Encode(bs []byte) string {
	if len(bs) == 0 {
		return ""
	}
	// encodedLength(n) = (n*8 - 1) / 5 + 1.
	n := (len(bs)*8-1)/5 + 1
	out := make([]byte, n)
	for k := n - 1; k >= 0; k-- {
		b := k * 5
		i := b / 8
		j := b % 8
		var c byte
		c = bs[i] >> j
		if i+1 < len(bs) {
			c |= bs[i+1] << (8 - j)
		}
		out[n-1-k] = nix32Chars[c&0x1f]
	}
	return string(out)
}

func appendUnique(xs []string, s string) []string {
	for _, x := range xs {
		if x == s {
			return xs
		}
	}
	return append(xs, s)
}

// shellQuoteFlags renders a list of flags for a bash `-c` script,
// single-quoted so no shell interpretation happens.
func shellQuoteFlags(flags []string) string {
	if len(flags) == 0 {
		return ""
	}
	parts := make([]string, 0, len(flags))
	for _, f := range flags {
		// Bash single-quote: replace ' with '\''.
		esc := strings.ReplaceAll(f, "'", `'\''`)
		parts = append(parts, "'"+esc+"'")
	}
	return strings.Join(parts, " ")
}
