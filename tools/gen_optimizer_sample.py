#!/usr/bin/env python3
"""Samples expr's optimizer test table as a behavioural equivalence table.

expr's optimizer rewrites ASTs (sum of a range into a formula, filter/map
fusion, count thresholds, ...). mbel implements only constant folding, and
the coverage matrix records why the rest is not ported: the rewrites change
observable behaviour under mbel's contracts (function names in error
messages, undefined-vs-null, dynamic Eval semantics, the range memory
budget). What must still hold is the *result*: evaluating these inputs
without the passes must produce what expr produces with them.

So this reads `optimizer/optimizer_test.go`'s TestOptimize table (input and
expected value) and freezes it as a MoonBit table.
expr_test/optimizer_sample_test.mbt evaluates each input on both engines
and compares.

Run from the repository root:  python3 tools/gen_optimizer_sample.py
Set EXPR_SRC to the reference checkout (default: the sibling `../expr`).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT = os.path.join(os.path.dirname(ROOT), "expr")
SRC = os.environ.get("EXPR_SRC", DEFAULT)
OUT = os.path.join(ROOT, "expr_test/optimizer_sample_data_test.mbt")


def normalize(want):
    """Go literal in the table's want column -> canonical text."""
    w = want.strip()
    m = re.fullmatch(r"float64\((.*)\)", w)
    if m:
        return m.group(1)
    return w


def main():
    path = os.path.join(SRC, "optimizer/optimizer_test.go")
    if not os.path.exists(path):
        sys.exit("not found: %s (set EXPR_SRC)" % path)
    body = open(path, encoding="utf-8").read()
    start = body.index("func TestOptimize(")
    seg = body[start : body.index("\nfunc ", start + 10)]
    rows = re.findall(r"\n\t\t\{`(.*?)`,\s*(.*?)\},", seg, re.S)
    if not rows:
        sys.exit("no rows extracted from %s" % path)
    lines = [
        "// AUTO-GENERATED from the reference expr optimizer test table — do not edit.",
        "// Regenerate with tools/gen_optimizer_sample.py.",
        "//",
        "// expr's TestOptimize table (optimizer/optimizer_test.go): each input",
        "// with the value expr produces *with* its optimizer passes enabled.",
        "// expr_test/optimizer_sample_test.mbt evaluates the same inputs without",
        "// those passes and asserts the same result, which is the property that",
        "// matters given the passes are documented as not portable.",
        "",
        "///|",
        "let optimizer_sample_cases : Array[(String, String)] = [",
    ]
    for e, w in rows:
        expr = e.strip().replace("\\", "\\\\").replace('"', '\\"')
        lines.append('  ("%s", "%s"),' % (expr, normalize(w)))
    lines.append("]")
    lines.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d cases)" % (os.path.relpath(OUT, ROOT), len(rows)))


if __name__ == "__main__":
    main()
