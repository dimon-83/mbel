#!/usr/bin/env python3
"""Regenerates engine_test/corpus_data_test.mbt from tools/corpus*.txt."""
def mbt_escape(s):
    out = []
    for ch in s:
        if ch == '\\': out.append('\\\\')
        elif ch == '"': out.append('\\"')
        elif ch == '\n': out.append('\\n')
        elif ch == '\r': out.append('\\r')
        elif ch == '\t': out.append('\\t')
        else: out.append(ch)
    return ''.join(out)

exprs, ctxs = [], []
import sys, os
base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for line in open(os.path.join(base, 'tools/corpus.txt')).read().split('\n'):
    if line.strip() == '': continue
    exprs.append(line); ctxs.append('')
for line in open(os.path.join(base, 'tools/corpus_ctx.txt')).read().split('\n'):
    if line.strip() == '': continue
    if '\t' in line:
        e, c = line.split('\t', 1); exprs.append(e); ctxs.append(c)
    else:
        exprs.append(line); ctxs.append('')
with open(os.path.join(base, 'engine_test/corpus_data_test.mbt'), 'w') as f:
    f.write('// AUTO-GENERATED from tools/corpus.txt + corpus_ctx.txt — do not edit.\n')
    f.write('// Regenerate with tools/gen_corpus_mbt.py\n\n///|\nlet corpus_exprs : Array[String] = [\n')
    for e in exprs: f.write('  "' + mbt_escape(e) + '",\n')
    f.write(']\n\n///|\nlet corpus_ctx_jsons : Array[String] = [\n')
    for c in ctxs: f.write('  "' + mbt_escape(c) + '",\n')
    f.write(']\n')
print("generated", len(exprs), "entries")
