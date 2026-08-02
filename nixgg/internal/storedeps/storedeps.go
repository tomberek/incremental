// Package storedeps scans compile flags and wrapper env values for
// /nix/store/<name-hash> roots. Those roots must appear in the
// derivation's inputs so Nix will actually make them available inside
// the sandbox — a bare -I/nix/store/... flag isn't enough by itself.
package storedeps

import (
	"regexp"
	"sort"
	"strings"
)

// Matches a /nix/store root: /nix/store/<32 chars>-<name-until-slash-or-space>.
// The name part is intentionally lenient — Nix names allow a-z0-9._+-
// but we don't want to whitelist too tightly and drop a legitimate ref.
var storePathRE = regexp.MustCompile(`/nix/store/[a-z0-9]{32}-[^/[:space:]:"]+`)

// From returns a sorted, deduplicated list of store roots referenced by
// any of the flag strings or by any value in the wrapper env JSON.
//
// wrapperEnvJSON is a compact JSON object (from wrapperenv.JSON). We
// don't parse it as JSON; we just regex-match store paths in the raw
// text. That's fine because the wrapper env values are opaque strings —
// we just need every store path they name to be an input to the drv.
func From(flags []string, wrapperEnvJSON string) []string {
	set := map[string]bool{}
	for _, f := range flags {
		for _, m := range storePathRE.FindAllString(f, -1) {
			set[m] = true
		}
	}
	for _, m := range storePathRE.FindAllString(wrapperEnvJSON, -1) {
		set[m] = true
	}
	out := make([]string, 0, len(set))
	for p := range set {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// AsJSONArray formats a slice of paths as a compact JSON array of
// strings. We do this manually — store paths have no characters
// requiring JSON escaping (only [a-z0-9-_./]+), so a plain quote is
// safe and cheap.
func AsJSONArray(paths []string) string {
	if len(paths) == 0 {
		return "[]"
	}
	var b strings.Builder
	b.WriteByte('[')
	for i, p := range paths {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteByte('"')
		b.WriteString(p)
		b.WriteByte('"')
	}
	b.WriteByte(']')
	return b.String()
}
