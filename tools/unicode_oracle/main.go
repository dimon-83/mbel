// Command unicode_oracle emits evaluator/unicode_classes.mbt: the general
// categories and scripts of Unicode, as code-point ranges, taken from Go's
// own `unicode` package.
//
// Taking them from Go is the point: expr's `\p{…}` is Go's regexp, so the
// tables agree with the reference implementation by construction rather
// than by hoping a different Unicode version matches. The regex translator
// expands `\p{L}` / `\p{Greek}` into a core character class built from
// these ranges.
//
// Usage (from tools/unicode_oracle):
//
//	go run . ../../evaluator/unicode_classes.mbt
package main

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"unicode"
)

func ranges(t *unicode.RangeTable) [][2]int {
	out := [][2]int{}
	for _, r := range t.R16 {
		step := int(r.Stride)
		for c := int(r.Lo); c <= int(r.Hi); c += step {
			out = append(out, [2]int{c, c})
		}
	}
	for _, r := range t.R32 {
		step := int(r.Stride)
		for c := int(r.Lo); c <= int(r.Hi); c += step {
			out = append(out, [2]int{c, c})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i][0] < out[j][0] })
	// merge adjacent
	merged := [][2]int{}
	for _, r := range out {
		if n := len(merged); n > 0 && r[0] == merged[n-1][1]+1 {
			merged[n-1][1] = r[1]
			continue
		}
		merged = append(merged, r)
	}
	return merged
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run . <output.mbt>")
		os.Exit(2)
	}
	names := []string{}
	for n := range unicode.Categories {
		names = append(names, n)
	}
	for n := range unicode.Scripts {
		names = append(names, n)
	}
	sort.Strings(names)

	var b strings.Builder
	b.WriteString("// SPDX-License-Identifier: Apache-2.0\n")
	b.WriteString("// AUTO-GENERATED from Go's unicode package — do not edit.\n")
	b.WriteString("// Regenerate with tools/unicode_oracle (see tools/README.md).\n")
	b.WriteString("//\n")
	b.WriteString("// expr's `\\p{…}` is Go's regexp, so these ranges are Go's own tables:\n")
	b.WriteString("// agreement is by construction rather than by matching Unicode versions.\n")
	b.WriteString("// The regex translator expands a class name into a core character class.\n\n")
	b.WriteString("///|\n")
	b.WriteString("let unicode_class_ranges : Array[(String, Array[(Int, Int)])] = [\n")
	total := 0
	for _, n := range names {
		var t *unicode.RangeTable
		if c, ok := unicode.Categories[n]; ok {
			t = c
		} else {
			t = unicode.Scripts[n]
		}
		rs := ranges(t)
		total += len(rs)
		parts := make([]string, 0, len(rs))
		for _, r := range rs {
			if r[0] == r[1] {
				parts = append(parts, fmt.Sprintf("(0x%X, 0x%X)", r[0], r[1]))
			} else {
				parts = append(parts, fmt.Sprintf("(0x%X, 0x%X)", r[0], r[1]))
			}
		}
		// wrap long tables over several lines
		b.WriteString("  (\n    \"" + n + "\",\n    [")
		for i, p := range parts {
			if i > 0 {
				b.WriteString(", ")
			}
			if i > 0 && i%8 == 0 {
				b.WriteString("\n     ")
			}
			b.WriteString(p)
		}
		b.WriteString("],\n  ),\n")
	}
	b.WriteString("]\n\n")
	b.WriteString("///|\n")
	b.WriteString("/// Ranges for a `\\p{…}` name (a general category like `L`, `Lu` or a\n")
	b.WriteString("/// script like `Greek`), or `None` when the name is not a class.\n")
	b.WriteString("pub fn unicode_class(name : String) -> Array[(Int, Int)]? {\n")
	b.WriteString("  for entry in unicode_class_ranges {\n")
	b.WriteString("    let (n, rs) = entry\n")
	b.WriteString("    if n == name {\n")
	b.WriteString("      return Some(rs)\n")
	b.WriteString("    }\n")
	b.WriteString("  }\n")
	b.WriteString("  match name {\n")
	b.WriteString("    // RE2 spells the whole code-point range `Any`; it is not a\n")
	b.WriteString("    // Unicode category, so it is not in Go's tables.\n")
	b.WriteString("    \"Any\" => Some([(0x0, 0x10FFFF)])\n")
	b.WriteString("    _ => None\n")
	b.WriteString("  }\n")
	b.WriteString("}\n")
	if err := os.WriteFile(os.Args[1], []byte(b.String()), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("names=%d ranges=%d\n", len(names), total)
}
