package shim

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/tbereknyei/nixgg/internal/classify"
	"github.com/tbereknyei/nixgg/internal/dispatch"
	"github.com/tbereknyei/nixgg/internal/expr"
	"github.com/tbereknyei/nixgg/internal/paths"
	"github.com/tbereknyei/nixgg/internal/realise"
	"github.com/tbereknyei/nixgg/internal/sandbox"
	"github.com/tbereknyei/nixgg/internal/storedeps"
	"github.com/tbereknyei/nixgg/internal/thunk"
	"github.com/tbereknyei/nixgg/internal/toolchain"
	"github.com/tbereknyei/nixgg/internal/wrapperenv"
)

// Link is the shim entrypoint for `cc ... foo.o bar.o -o baz` (no -c).
// It classifies every input by inspecting its symlink and produces a
// link thunk that references each input either by store path (already
// realised) or by relative sibling thunk import (deferred).
//
// If any input isn't a nixgg symlink at all — a plain .o that make
// left behind, or a system library the caller passes by name — we
// fall back to passthrough. We can't model the link without knowing
// how to represent every input in the Nix expression.
func Link(tool dispatch.Tool, args []string, cfg *toolchain.Config, l paths.Layout) error {
	// Refuse compile-family invocations that only *look* like a link.
	for _, a := range args {
		switch a {
		case "-c", "-E", "-S", "-M", "-MM":
			return Passthrough(cfg.RealCC, args)
		}
	}

	output, inputs, flags, ok := parseLinkArgs(args)
	if !ok {
		return Passthrough(cfg.RealCC, args)
	}

	logf("link %s <- %s", output, joinBase(inputs))

	// Classify each input.
	altPrefix := altStorePrefix(cfg.Store)
	linkInputs := make([]expr.Input, 0, len(inputs))
	jsonInputs := make([]expr.JSONDrvInput, 0, len(inputs))
	for _, in := range inputs {
		c := classify.Target(in, altPrefix, l)
		switch c.Kind {
		case classify.Store:
			linkInputs = append(linkInputs, expr.Input{
				Kind: "store", Ref: c.Ref, Name: filepath.Base(in),
			})
			jsonInputs = append(jsonInputs, expr.JSONDrvInput{
				Kind: "src", Ref: filepath.Base(c.Ref), Name: filepath.Base(in),
			})
		case classify.Thunk:
			linkInputs = append(linkInputs, expr.Input{
				Kind: "nix", Ref: c.Ref, Name: filepath.Base(in),
			})
		case classify.Drv:
			// Sandbox-mode input: previous shim produced a .drv here.
			// Only meaningful when we're also in sandbox mode.
			jsonInputs = append(jsonInputs, expr.JSONDrvInput{
				Kind: "drv", Ref: c.Ref, Name: filepath.Base(in),
			})
		default:
			logf("link passthrough: %s isn't a nixgg symlink (%s)", in, c.Kind)
			return Passthrough(cfg.RealCC, args)
		}
	}

	wrapperEnvJSON, err := wrapperenv.JSON()
	if err != nil {
		return err
	}
	storeDeps := storedeps.From(flags, wrapperEnvJSON)

	// Sandbox mode: emit JSON, submit as this outer derivation's output.
	if sandbox.Enabled() {
		return linkSandbox(cfg, tool, output, jsonInputs, flags, storeDeps, wrapperEnvJSON)
	}

	e := expr.Link(expr.LinkParams{
		Helpers:        cfg.Helpers,
		Tool:           tool.Basename(),
		OutName:        filepath.Base(output),
		Inputs:         linkInputs,
		Flags:          flags,
		StoreDepsJSON:  storedeps.AsJSONArray(storeDeps),
		WrapperEnvJSON: wrapperEnvJSON,
	})

	// Links are placeholder-mode by default: the resulting binary isn't
	// usually consumed inside the same make invocation. `nixgg force
	// <target>` — or `nixgg build --target …` — realises at the end.
	id := thunk.Compute(e)
	thunkPath, err := thunk.Write(l, id, e)
	if err != nil {
		return err
	}
	if err := thunk.LinkPlaceholder(l, output, thunkPath); err != nil {
		return err
	}
	if err := thunk.RecordSymlink(l, id, output); err != nil {
		return err
	}
	logf("  thunk:      %s", thunkPath)

	// NIXGG_AUTOFORCE=1: realise the link's DAG inline, so a plain
	// `NIXGG_AUTOFORCE=1 make` produces real binaries in the working
	// tree without a wrapper (`nixgg build …`). Only the link shim
	// does this; compile/archive shims stay placeholder so we don't
	// force intermediate .o/.a files that are just going to be linked
	// into something else on the next line.
	if os.Getenv("NIXGG_AUTOFORCE") == "1" {
		if err := realise.Realise(l, cfg, thunkPath, output); err != nil {
			return err
		}
	}
	return nil
}

// parseLinkArgs pulls out -o OUT and every .o/.a input token, treating
// everything else as a flag. Order matters for the flags — link line
// order affects symbol resolution — but not for the inputs (the
// linker.nix helper preserves order).
func parseLinkArgs(args []string) (output string, inputs, flags []string, ok bool) {
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-o":
			if i+1 >= len(args) {
				return
			}
			output = args[i+1]
			i++
		case strings.HasPrefix(a, "-o") && len(a) > 2:
			output = a[2:]
		case isLinkInput(a):
			inputs = append(inputs, a)
		// Drop dep-file flags — link-time -M is meaningless in our thunk.
		case a == "-M" || a == "-MM" || a == "-MG" || a == "-MP" || a == "-MD" || a == "-MMD":
			// skip
		case a == "-MF" || a == "-MT" || a == "-MQ":
			i++ // skip value
		default:
			flags = append(flags, a)
		}
	}
	if len(inputs) == 0 || output == "" {
		return "", nil, nil, false
	}
	return output, inputs, flags, true
}

func isLinkInput(a string) bool {
	// .o (object), .a (archive), .xo (redis's position-independent
	// object for its shared-object test modules), .lo (libtool object).
	ext := strings.ToLower(filepath.Ext(a))
	return ext == ".o" || ext == ".a" || ext == ".xo" || ext == ".lo"
}

// altStorePrefix returns the on-disk root for `local?root=...` stores.
// For a system or `auto` store, returns "".
func altStorePrefix(storeURL string) string {
	const prefix = "local?root="
	if strings.HasPrefix(storeURL, prefix) {
		return strings.TrimPrefix(storeURL, prefix)
	}
	return ""
}

func joinBase(inputs []string) string {
	var b strings.Builder
	for i, in := range inputs {
		if i > 0 {
			b.WriteByte(' ')
		}
		b.WriteString(filepath.Base(in))
	}
	return b.String()
}

// linkSandbox handles NIXGG_SANDBOX=1: emit a JSON drv describing
// this link, hand it to `nix derivation add`, and submit the returned
// .drv as the current outer derivation's output.
//
// Every link in a sandbox is a candidate final output. That's fine —
// nix store submit-output only allows one submission per output name,
// so a build with multiple links must arrange for only one to be
// "the" output (via NIXGG_SANDBOX_TARGET, matched against the -o
// output). Other link steps just add their drvs to the store without
// submitting; the consumer's `builtins.outputOf` reaches them
// transitively through the target's inputs.drvs.
func linkSandbox(
	cfg *toolchain.Config,
	tool dispatch.Tool,
	output string,
	inputs []expr.JSONDrvInput,
	flags []string,
	storeDeps []string,
	wrapperEnvJSON string,
) error {
	outName := filepath.Base(output)
	wrapperEnv, err := decodeStringMap(wrapperEnvJSON)
	if err != nil {
		return err
	}
	drv := expr.LinkJSON(expr.LinkJSONParams{
		Name:        "bin-" + outName,
		OutName:     outName,
		System:      cfg.System,
		Bash:        cfg.BashRoot,
		Coreutils:   cfg.CoreutilsRoot,
		Compiler:    cfg.CompilerRoot,
		Tool:        tool.Basename(),
		Inputs:      inputs,
		Flags:       flags,
		Placeholder: "/" + expr.OutPlaceholderNix32,
		ExtraSrcs: []string{
			baseNameOf(cfg.BashRoot),
			baseNameOf(cfg.CoreutilsRoot),
			baseNameOf(cfg.CompilerRoot),
		},
		Env: wrapperEnv,
	})
	for _, sd := range storeDeps {
		drv.Inputs.Srcs = append(drv.Inputs.Srcs, baseNameOf(sd))
	}

	drvPath, err := sandbox.DerivationAdd(cfg, drv)
	if err != nil {
		return err
	}
	if err := sandbox.PointOutputAtDrv(output, drvPath); err != nil {
		return err
	}
	logf("  drv:        %s", drvPath)

	// Submit if this matches the caller's declared target.
	// NIXGG_SANDBOX_TARGET holds the abs or basename path the outer
	// build wants exposed as `out`. If unset, submit every link
	// (which will error on the second submit — user should set
	// TARGET when they have multiple links).
	//
	// mkNixggBuild names the outer drv "bin-<target>.drv" to match
	// our inner link drv's name, so no rename is needed.
	target := os.Getenv("NIXGG_SANDBOX_TARGET")
	if target == "" || matchesTarget(target, output) {
		if err := sandbox.SubmitOutput(cfg, drvPath, "out"); err != nil {
			logf("  submit-output: %v", err)
		} else {
			logf("  submitted: %s", drvPath)
		}
	}
	return nil
}

// matchesTarget returns true if `target` (which may be a basename,
// a relative path, or an absolute path) refers to `output`.
func matchesTarget(target, output string) bool {
	if target == output {
		return true
	}
	if abs, err := filepath.Abs(output); err == nil && target == abs {
		return true
	}
	if filepath.Base(target) == filepath.Base(output) {
		return true
	}
	return false
}

var _ = fmt.Sprintf // silence unused-import warning if fmt goes away later
var _ = os.Getpid
