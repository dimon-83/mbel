#!/usr/bin/env python3
"""Freezes expr's date() results into a MoonBit table.

tools/time_oracle evaluates each input of tools/time_corpus.txt exactly as
expr's `date()` does (the 7-layout scan with Go's time.Parse) and prints
int64 UnixNano, or ERR. expr_test/time_want_test.mbt then asserts mbel's
`date()` produces the same instant — including the numeric UTC offsets in
RFC3339 strings, which is where expr supports fixed offsets.

Run from the repository root:  python3 tools/gen_time_mbt.py
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tools/time_corpus.txt")
ORACLE_DIR = os.path.join(ROOT, "tools/time_oracle")
OUT = os.path.join(ROOT, "expr_test/time_want_data_test.mbt")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\"}


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
    return s.replace("\\", "\\\\").replace('"', '\\"')


def main():
    inputs = [
        unescape(l)
        for l in open(CORPUS, encoding="utf-8").read().split("\n")
        if l and not l.startswith("#")
    ]
    env = dict(os.environ, GOCACHE=os.path.join(ROOT, "_build/gocache"))
    proc = subprocess.run(
        ["go", "run", ".", CORPUS],
        cwd=ORACLE_DIR,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        sys.exit("time oracle failed: " + proc.stderr.strip())
    wants = {}
    for line in proc.stdout.split("\n"):
        if not line.strip():
            continue
        idx, want = line.split("\t", 1)
        wants[int(idx)] = want
    if len(wants) != len(inputs):
        sys.exit("oracle returned %d verdicts for %d cases" % (len(wants), len(inputs)))
    lines = [
        "// AUTO-GENERATED from tools/time_corpus.txt — do not edit.",
        "// Regenerate with tools/gen_time_mbt.py (runs Go's time.Parse via",
        "// tools/time_oracle, mirroring expr's date() layout scan).",
        "//",
        "// `want` is int64 nanoseconds since the Unix epoch, or ERR when",
        "// expr's date() rejects the input.",
        "",
        "///|",
        "let time_want_cases : Array[(String, String)] = [",
    ]
    for i, s in enumerate(inputs):
        lines.append('  ("%s", "%s"),' % (mbt(s), wants[i]))
    lines.append("]")
    lines.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d cases)" % (os.path.relpath(OUT, ROOT), len(inputs)))


if __name__ == "__main__":
    main()
