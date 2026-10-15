#!/usr/bin/env python3
"""Freezes expr's TestParse AST shapes into a MoonBit table.

Runs tools/parse_oracle (the real expr parser, dumping in mbel's `dump()`
convention) over tools/parse_corpus.txt and writes
expr_test/parse_want_data_test.mbt. expr_test/parse_want_test.mbt then
asserts mbel's parser produces the same shape — the differential check the
coverage matrix tracks as the parser gate item.

Run from the repository root:  python3 tools/gen_parse_mbt.py
Requires the Go toolchain and the reference checkout path in
tools/parse_oracle/go.mod.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tools/parse_corpus.txt")
ORACLE_DIR = os.path.join(ROOT, "tools/parse_oracle")
OUT = os.path.join(ROOT, "engine_test/../expr_test/parse_want_data_test.mbt")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"'}


def unescape(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s) and s[i + 1] in ESCAPES:
            out.append(ESCAPES[s[i + 1]])
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def mbt(s):
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ord(ch) < 0x20:
            out.append("\\u{%X}" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def main():
    exprs = []
    for line in open(CORPUS, encoding="utf-8").read().split("\n"):
        if not line or line.startswith("#"):
            continue
        exprs.append(unescape(line))
    # Keep Go's build cache inside the repo: the harness sandbox only
    # allows writes under the workspace, and the default cache lives in
    # the user's home directory.
    env = dict(os.environ, GOCACHE=os.path.join(ROOT, "_build/gocache"))
    proc = subprocess.run(
        ["go", "run", ".", CORPUS],
        cwd=ORACLE_DIR,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        sys.exit("parse oracle failed: " + proc.stderr.strip())
    wants = {}
    for line in proc.stdout.split("\n"):
        if not line.strip():
            continue
        idx, want = line.split("\t", 1)
        wants[int(idx)] = unescape(want)
    if len(wants) != len(exprs):
        sys.exit("oracle returned %d verdicts for %d cases" % (len(wants), len(exprs)))
    lines = [
        "// AUTO-GENERATED from tools/parse_corpus.txt — do not edit.",
        "// Regenerate with tools/gen_parse_mbt.py (runs the expr parser via",
        "// tools/parse_oracle).",
        "//",
        '// `want` is expr\'s AST for the same source, rendered in mbel\'s',
        "// dump() convention; expr_test/parse_want_test.mbt asserts mbel's",
        "// parser produces exactly this shape.",
        "",
        "///|",
        "let parse_want_cases : Array[(String, String)] = [",
    ]
    for i, e in enumerate(exprs):
        lines.append('  ("%s", "%s"),' % (mbt(e), mbt(wants[i])))
    lines.append("]")
    lines.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d cases)" % (os.path.relpath(OUT, ROOT), len(exprs)))


if __name__ == "__main__":
    main()
