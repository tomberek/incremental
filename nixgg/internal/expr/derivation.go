// Package expr constructs Nix derivations. A single Derivation struct
// holds every field that both wire formats — the `.nix` thunk file
// (native mode, run through `nix-instantiate`) and the JSON drv
// description (sandbox mode, run through `nix derivation add`) — need
// to agree on. Both serializers work off the same struct, so if you
// add a new attribute you can't accidentally set it in one format and
// forget the other.
//
// The invariant we care about: same Derivation → same drv hash,
// regardless of which serializer produces the wire bytes. Enforced
// externally by tests/drv-equivalence.sh (runs both paths, compares
// resulting drv-store-paths).
package expr

import (
	"fmt"
	"strings"
)

// Kind identifies which of the three build steps this derivation
// represents. Different Kinds emit different shell scripts and
// slightly different helper Nix files, but share the same env-dict
// shape.
type Kind int

const (
	KindCompile Kind = iota // per-TU compile: builder.nix
	KindLink                // linker step: linker.nix
	KindArchive             // ar step: archiver.nix
)

// Derivation is the intermediate representation both serializers
// consume. Fields mirror the union of what builder.nix / linker.nix /
// archiver.nix accept plus the fields Nix itself requires (name,
// system, builder, args, env, inputs, outputs).
//
// Not every field applies to every Kind:
//   - Compile uses SrcStore, Source, OutName, Flags.
//   - Link uses Inputs, Flags.
//   - Archive uses Inputs, ARFlags.
//
// StoreDeps and WrapperEnv apply to all Kinds.
type Derivation struct {
	Kind Kind

	// The name Nix assigns to the derivation's .drv basename. For
	// compile this is "tu-<outName>"; link "bin-<outName>"; archive
	// "ar-<outName>".
	Name string

	// Nix system (e.g. "x86_64-linux").
	System string

	// Toolchain roots — full /nix/store/… paths. All three kinds use
	// bash (builder) + coreutils (PATH). Compile + link use the
	// compiler; archive uses the binutils dir (via AR).
	Bash, Coreutils string
	Compiler        string // gcc-wrapper root; unused by Archive
	AR              string // binutils root (parent of bin/ar); Archive only

	// Compile-specific.
	Tool     string // "cc", "gcc", "c++", "g++"; used by Compile + Link
	SrcStore string // /nix/store/…-<tuID>: the staged src tree
	Source   string // relative to SrcStore, e.g. "src/foo.c"
	OutName  string // e.g. "foo.o"

	// Link + Archive: inputs (either sibling drvs or already-realised
	// store paths). Compile leaves this empty.
	Inputs []derivInput

	// Link + Compile: compiler flags. Archive uses ARFlags instead.
	Flags []string

	// Archive-only: `ar` modifier string (e.g. "rcs").
	ARFlags string

	// /nix/store/… roots referenced by Flags or WrapperEnv content;
	// must be mounted in the sandbox. Serialized as _storeDeps env var
	// (colon-joined) and threaded into inputs.srcs (JSON mode) /
	// storeDepsJSON (native mode).
	StoreDeps []string

	// Nix's gcc-wrapper env (NIX_CFLAGS_COMPILE, NIX_LDFLAGS, etc.).
	// Preserved verbatim in the env dict.
	WrapperEnv map[string]string
}

// derivInput is the internal per-input record used by Derivation's
// serializers. Kept separate from the shim-facing Input type in
// expr.go (which uses Kind="store"/"nix" via a different field name
// for historical reasons). inputsFromExpr / inputsFromJSON convert.
type derivInput struct {
	// InputKind = "store" (already realised, use the store path as
	// builtins.storePath) or "nix" (a sibling drv/thunk we
	// reference — becomes `import /path/thunk.nix` in native mode
	// and inputs.drvs entry in JSON mode).
	InputKind string
	// Ref: for "store", a canonical /nix/store/<hash>-<name> root;
	// for "nix", the absolute path to the sibling drv/thunk.
	Ref string
	// Name: the basename inside that ref's output dir (e.g. "foo.o").
	Name string
}

// outputPlaceholder returns the `builtins.placeholder "out"` value —
// what every derivation's `$out` env var interpolates to at build
// time. Same digest for every CA derivation with a single `out`
// output; caching for one call site is fine.
func outputPlaceholder() string { return "/" + OutPlaceholderNix32 }

// script returns the bash `-c` body the derivation runs. Byte-
// identical between native (interpreted by builder.nix's own args)
// and JSON (baked directly into the drv's args) — that's what makes
// their drv hashes match.
//
// All variants use env-var indirection ($src, $source, $outName)
// where possible: the shell script's byte content shouldn't depend
// on the concrete store paths, only on tool/flags/output layout.
func (d *Derivation) script() string {
	pathPrefix := fmt.Sprintf(`export PATH="%s/bin:%s/bin"`, d.Coreutils, d.Compiler)
	if d.Kind == KindArchive {
		pathPrefix = fmt.Sprintf(`export PATH="%s/bin:%s/bin"`, d.Coreutils, d.AR)
	}
	switch d.Kind {
	case KindCompile:
		return fmt.Sprintf(
			`set -euo pipefail
%s
mkdir -p "$out"
cd "$src"
"%s" %s -c "$source" -o "$out/$outName"
`, pathPrefix, d.Tool, shellQuoteFlags(d.Flags))
	case KindLink:
		return fmt.Sprintf(
			`set -euo pipefail
%s
mkdir -p "$out"
"%s" %s %s -o "$out/%s"
`, pathPrefix, d.Tool, shellQuoteFlags(d.Flags), d.linkerInputs(), d.OutName)
	case KindArchive:
		return fmt.Sprintf(
			`set -euo pipefail
%s
mkdir -p "$out"
"%s/bin/ar" '%s' "$out/%s" %s
`, pathPrefix, d.AR, d.ARFlags, d.OutName, d.linkerInputs())
	}
	return ""
}

// linkerInputs renders the input list into the shell script's argv,
// as a single space-separated string of quoted absolute paths.
// Called by Link and Archive scripts.
//
//   - InputKind="store": Ref is a canonical /nix/store/<hash>-<name>
//     root; script sees '<Ref>/<Name>'.
//   - InputKind="nix":   Ref is the full drv-store path
//     (/nix/store/<hash>-<name>.drv); script sees
//     '<ca-output-placeholder>/<Name>'. Nix substitutes the
//     placeholder with the real output path at build time.
func (d *Derivation) linkerInputs() string {
	parts := make([]string, 0, len(d.Inputs))
	for _, in := range d.Inputs {
		switch in.InputKind {
		case "store":
			ref := in.Ref
			if !strings.HasPrefix(ref, "/nix/store/") {
				ref = "/nix/store/" + ref
			}
			parts = append(parts, fmt.Sprintf("'%s/%s'", ref, in.Name))
		case "nix":
			ph := caOutputPlaceholder(in.Ref, "out")
			parts = append(parts, fmt.Sprintf("'%s/%s'", ph, in.Name))
		}
	}
	return strings.Join(parts, " ")
}

// toJSON serialises this Derivation for `nix derivation add`. The
// caller passes extraSrcs (basenames of already-realised store paths
// the sandbox must mount) and optional wrapper-env overrides via
// WrapperEnv on the struct. Inputs are split into inputs.drvs (for
// Kind=="nix") and inputs.srcs (for Kind=="store").
func (d *Derivation) toJSON(extraSrcs []string, _reserved any) JSONDrv {
	drvs := map[string]JSONDrvRef{}
	srcs := append([]string{}, extraSrcs...)
	seenSrc := map[string]bool{}
	for _, s := range srcs {
		seenSrc[s] = true
	}
	for _, in := range d.Inputs {
		switch in.InputKind {
		case "nix":
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
		case "store":
			base := in.Ref
			if i := strings.LastIndexByte(base, '/'); i >= 0 {
				base = base[i+1:]
			}
			if !seenSrc[base] {
				srcs = append(srcs, base)
				seenSrc[base] = true
			}
		}
	}
	for _, sd := range d.StoreDeps {
		base := sd
		if i := strings.LastIndexByte(base, '/'); i >= 0 {
			base = base[i+1:]
		}
		if !seenSrc[base] {
			srcs = append(srcs, base)
			seenSrc[base] = true
		}
	}
	return JSONDrv{
		Name:    d.Name,
		System:  d.System,
		Builder: d.Bash + "/bin/bash",
		Args:    []string{"-c", d.script()},
		Env:     d.envDict(),
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

// envDict is the env-var dict every derivation gets. Both serializers
// use it as-is — that's what pins them to the same hash.
func (d *Derivation) envDict() map[string]string {
	env := map[string]string{
		"out":            outputPlaceholder(),
		"name":           d.Name,
		"system":         d.System,
		"builder":        d.Bash + "/bin/bash",
		"outputHashAlgo": "sha256",
		"outputHashMode": "nar",
		"_storeDeps":     strings.Join(d.StoreDeps, ":"),
	}
	// Compile derivations pass source/outName/src via env vars too
	// (that's what builder.nix's script consults — see the
	// `cd "$src"` / `"$source"` / `"$outName"` in script()).
	if d.Kind == KindCompile {
		env["src"] = d.SrcStore
		env["source"] = d.Source
		env["outName"] = d.OutName
	}
	for k, v := range d.WrapperEnv {
		env[k] = v
	}
	return env
}
