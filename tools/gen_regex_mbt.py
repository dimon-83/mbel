#!/usr/bin/env python3
"""Regenerates engine_test/regex_re2_data_test.mbt from the Go RE2 oracle.

Reads tools/regex_corpus.txt, asks tools/regex_oracle.go (Go's regexp,
i.e. RE2) for the verdict on every case, and freezes the results into a
MoonBit table. engine_test/regex_re2_test.mbt then asserts that mbel's
`matches` agrees with Go on every row -- a mismatch means the RE2 -> core
translation diverged, and the test names the offending case.

Run from the repository root:

    python3 tools/gen_regex_mbt.py

Requires the Go toolchain (the same one used for the upstream diff
harness in this directory).
"""
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "tools/regex_corpus.txt")
ORACLE = os.path.join(ROOT, "tools/regex_oracle.go")
OUT = os.path.join(ROOT, "engine_test/regex_re2_data_test.mbt")

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "f": "\f", "v": "\v", "\\": "\\", '"': '"'}


def unescape(s):
    """Decodes the corpus escape convention (see the corpus header)."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt in ESCAPES:
                out.append(ESCAPES[nxt])
                i += 2
                continue
            out.append("\\")
            out.append(nxt)
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def mbt_escape(s):
    """Renders a Python string as a MoonBit string literal body."""
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
    cases = []
    for line in open(CORPUS, encoding="utf-8").read().split("\n"):
        if not line or line.startswith("#"):
            continue
        pat, subj = line.split("\t", 1)
        cases.append((unescape(pat), unescape(subj)))

    # Keep Go's build cache inside the repo: the default lives in the user's
    # home directory, which the project's file sandbox does not allow.
    env = dict(os.environ, GOCACHE=os.path.join(ROOT, "_build/gocache"))
    proc = subprocess.run(
        ["go", "run", ORACLE, CORPUS],
        cwd=ROOT,
        capture_output=True,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        sys.exit("regex oracle failed: " + proc.stderr.strip())
    verdicts = {}
    for line in proc.stdout.split("\n"):
        if not line.strip():
            continue
        idx, verdict = line.split("\t")
        verdicts[int(idx)] = verdict
    if len(verdicts) != len(cases):
        sys.exit("oracle returned %d verdicts for %d cases" % (len(verdicts), len(cases)))

    goversion = subprocess.run(["go", "version"], capture_output=True, text=True).stdout.strip()
    date = datetime.date.today().isoformat()

    lines = [
        "// AUTO-GENERATED from tools/regex_corpus.txt — do not edit.",
        "// Regenerate with tools/gen_regex_mbt.py",
        "//",
        "// Expected column is Go's regexp verdict (%s) on" % goversion,
        "// %s: \"true\"/\"false\" is the match result, \"error\" means Go" % date,
        "// rejected the pattern. engine_test/regex_re2_test.mbt asserts mbel",
        "// agrees on every row (match value, or a raised error).",
        "",
        "///|",
        "let regex_re2_cases : Array[(String, String, String)] = [",
    ]
    for i, (pat, subj) in enumerate(cases):
        lines.append(
            '  ("%s", "%s", "%s"),' % (mbt_escape(pat), mbt_escape(subj), verdicts[i])
        )
    lines.append("]")
    lines.append("")
    open(OUT, "w", encoding="utf-8").write("\n".join(lines))
    print("wrote %s (%d cases)" % (os.path.relpath(OUT, ROOT), len(cases)))


if __name__ == "__main__":
    main()
