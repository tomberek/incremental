package shim

import (
	"path/filepath"
	"strings"

	"github.com/tbereknyei/nixgg/internal/classify"
	"github.com/tbereknyei/nixgg/internal/expr"
	"github.com/tbereknyei/nixgg/internal/paths"
	"github.com/tbereknyei/nixgg/internal/storedeps"
	"github.com/tbereknyei/nixgg/internal/thunk"
	"github.com/tbereknyei/nixgg/internal/toolchain"
	"github.com/tbereknyei/nixgg/internal/wrapperenv"
)

// Archive is the shim entrypoint for `ar <mods> archive.a obj1 obj2 …`.
// It parses the ar modifier string, resolves inputs the same way link
// does, and writes an archive thunk.
//
// We don't model `ar r archive.a …` operations that mutate an existing
// archive — every archive we build is fresh. Modifier flags like
// `s` (index), `u` (update), `q` (quick-append) still make it into the
// thunk expression's ARFlags so `ar` inside the sandbox is called
// with the caller's exact intent.
func Archive(args []string, cfg *toolchain.Config, l paths.Layout) error {
	modifiers, archive, inputs, ok := parseARArgs(args)
	if !ok {
		return Passthrough(realARFor(cfg), args)
	}

	logf("archive %s <- %s", archive, joinBase(inputs))

	altPrefix := altStorePrefix(cfg.Store)
	arInputs := make([]expr.Input, 0, len(inputs))
	for _, in := range inputs {
		c := classify.Target(in, altPrefix)
		switch c.Kind {
		case classify.Store:
			arInputs = append(arInputs, expr.Input{
				Kind: "store", Ref: c.Ref, Name: filepath.Base(in),
			})
		case classify.Thunk:
			arInputs = append(arInputs, expr.Input{
				Kind: "nix", Ref: c.Ref, Name: filepath.Base(in),
			})
		default:
			logf("ar passthrough: %s isn't a nixgg symlink (%s)", in, c.Kind)
			return Passthrough(realARFor(cfg), args)
		}
	}

	wrapperEnvJSON, err := wrapperenv.JSON()
	if err != nil {
		return err
	}
	// Archives have no flag list of their own; the CA hash comes from
	// inputs + modifiers. Wrapper env still matters if any input was
	// compiled with -fPIC / whatever, so we plumb it.
	storeDeps := storedeps.From(nil, wrapperEnvJSON)

	e := expr.Archive(expr.ArchiveParams{
		Helpers:        cfg.Helpers,
		OutName:        filepath.Base(archive),
		Inputs:         arInputs,
		ARFlags:        modifiers,
		StoreDepsJSON:  storedeps.AsJSONArray(storeDeps),
		WrapperEnvJSON: wrapperEnvJSON,
	})

	id := thunk.Compute(e)
	thunkPath, err := thunk.Write(l, id, e)
	if err != nil {
		return err
	}
	if err := thunk.LinkPlaceholder(archive, thunkPath); err != nil {
		return err
	}
	if err := thunk.RecordSymlink(l, id, archive); err != nil {
		return err
	}
	logf("  thunk:      %s", thunkPath)
	return nil
}

// parseARArgs pulls the modifier string, archive path, and input list.
// The classic `ar` CLI has three forms we care about:
//
//	ar rcs   archive.a  obj1 obj2   (rcs = create+replace+index)
//	ar -rcs  archive.a  obj1 obj2   (leading dash tolerated by GNU ar)
//	ar Drcs  archive.a  obj1 obj2   (D = deterministic)
//
// Everything else — tar-like operations, positional -N, `ranlib`-style
// invocations — we pass through unmodeled.
func parseARArgs(args []string) (modifiers, archive string, inputs []string, ok bool) {
	if len(args) < 2 {
		return
	}
	modifiers = args[0]
	// Tolerate GNU's leading dash.
	modifiers = strings.TrimPrefix(modifiers, "-")
	// A modifier string is 1+ chars from a fixed alphabet. Anything
	// else, we bail — it's a positional-count invocation like
	// `ar rN 3 archive.a obj` that we don't model.
	if !isARModifiers(modifiers) {
		return
	}
	archive = args[1]
	for _, in := range args[2:] {
		if !strings.HasSuffix(in, ".o") {
			// Non-.o input to ar — skip modeling.
			return "", "", nil, false
		}
		inputs = append(inputs, in)
	}
	if archive == "" || len(inputs) == 0 {
		return "", "", nil, false
	}
	return modifiers, archive, inputs, true
}

func isARModifiers(s string) bool {
	if s == "" {
		return false
	}
	// Union of the modifier characters ar accepts. Anything outside
	// means we're looking at a positional arg, not modifiers.
	allowed := "cruvsDxtpqRUbNaimoPS"
	for _, r := range s {
		if !strings.ContainsRune(allowed, r) {
			return false
		}
	}
	return true
}

// realARFor returns the sibling `ar` binary next to the pinned gcc.
// GCC wrappers ship an `ar` in the same bin/ dir; that's what we
// want the passthrough to hit, not whatever's earliest on PATH.
func realARFor(cfg *toolchain.Config) string {
	return filepath.Join(filepath.Dir(cfg.RealCC), "ar")
}
