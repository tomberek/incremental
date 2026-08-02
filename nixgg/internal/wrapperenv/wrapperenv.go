// Package wrapperenv builds the JSON object of `NIX_*` env vars that
// need to flow into the Nix compile/link derivation.
//
// Nix's gcc-wrapper consults NIX_CFLAGS_COMPILE, NIX_LDFLAGS,
// NIX_HARDENING_ENABLE, and their per-target-triple suffixed variants
// at build time. Our derivations don't inherit the caller's env, so we
// capture these here and pass them along.
package wrapperenv

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
)

// bases are the NIX_* variables the gcc-wrapper actually reads.
// Any others are ignored — we don't want to bake the whole environment
// into every derivation's CA hash.
var bases = []string{
	"NIX_CFLAGS_COMPILE",
	"NIX_CFLAGS_LINK",
	"NIX_LDFLAGS",
	"NIX_HARDENING_ENABLE",
}

// JSON returns a sorted, compact JSON object of the wrapper env vars
// present in the current environment. The object is embedded verbatim
// into the thunk expression; sorted keys keep byte-content stable so
// two runs with identical env produce identical thunk IDs.
func JSON() (string, error) {
	triple := detectTriple()
	kv := map[string]string{}
	if triple != "" {
		kv["NIX_CC_WRAPPER_TARGET_HOST_"+triple] = "1"
	}
	for _, base := range bases {
		val := os.Getenv(base)
		if triple != "" {
			// The triple-suffixed variant wins if set — matches nix's
			// gcc-wrapper precedence.
			suffix := base + "_" + strings.ReplaceAll(triple, "-", "_")
			if v := os.Getenv(suffix); v != "" {
				val = v
			}
		}
		if val == "" {
			continue
		}
		kv[base] = val
		if triple != "" {
			kv[base+"_"+strings.ReplaceAll(triple, "-", "_")] = val
		}
	}
	if len(kv) == 0 {
		return "{}", nil
	}
	// Marshal by sorted keys — json.Marshal on a map already does that,
	// but be explicit so the guarantee is visible.
	keys := make([]string, 0, len(kv))
	for k := range kv {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		kj, _ := json.Marshal(k)
		vj, _ := json.Marshal(kv[k])
		b.Write(kj)
		b.WriteByte(':')
		b.Write(vj)
	}
	b.WriteByte('}')
	return b.String(), nil
}

// detectTriple looks for NIX_CC_WRAPPER_TARGET_HOST_<triple>=1 in env.
// The nix gcc-wrapper sets exactly one such var to identify the host
// target triple (e.g. x86_64-unknown-linux-gnu). Returns "" if not set.
func detectTriple() string {
	const prefix = "NIX_CC_WRAPPER_TARGET_HOST_"
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, prefix) {
			continue
		}
		eq := strings.IndexByte(kv, '=')
		if eq < 0 {
			continue
		}
		return kv[len(prefix):eq]
	}
	return ""
}
