# Stage-3 differential harness

Compares mbel against the real Jexl (node) on identical expression
corpora. Both sides must print byte-identical canonical lines.

## Files
- `corpus.txt` — 180 hand-written expressions incl. error cases
- `fuzz1.txt` (seed 42), `fuzz.txt` (seed 20260904) — generated corpora
- `jexl_driver.js` — JS side: evaluates each corpus line with the real
  Jexl (`evalSync`) and prints canonical JSON-ish lines
- `run_diff.sh` — runs both sides and diffs

## Usage
    ./tools/run_diff.sh corpus
    ./tools/run_diff.sh fuzz1
    ./tools/run_diff.sh fuzz

## Canonical format
Values serialize identically on both sides: `null`, `true`, numbers via
shortest repr (`4`, `4.5`), JSON-escaped strings, arrays `[..]`,
objects `{k:v,..}` (insertion order), and sentinels `{"$undef":true}`,
`{"$nan":true}`, `{"$inf":true}`, `{"$ninf":true}`. Errors on both
sides print `{"$error":true}` (message text is not compared).

## Verified scope (2026-09-04)
- corpus: 180/180 identical
- fuzz1 (seed 42): 1154/1154 identical
- fuzz (seed 20260904): 1999/2000 identical; the single difference is
  `8 ^ [2.5]` where Math.pow (V8) and MoonBit pow differ by 1 ulp —
  a libm divergence, not a logic bug. See docs/parity-contract.md.

Transforms registered identically on both runners for corpus lines:
`dbl` (v*2), `first` (arr[0] or undefined), `concatWith` (JS `+`).

## Interactive use with a JSON context

    moon run cmd/main -- '6+x*2>10 ? "big" : "small"' '{"x": 3}'
    moon run cmd/main -- 'user.name + " scored " + (score*10)' \
      '{"user": {"name": "alice"}, "score": 8.5}'
    moon run cmd/main -- 'items[.price <= 2].name' \
      '{"items": [{"name":"apple","price":1.5}, {"name":"plum","price":2}]}'

argv[1] is the expression (or a newline-separated corpus), argv[2] the
optional JSON context. JSON null → NullVal, numbers → NumVal, objects
keep insertion order. Verified identical to real Jexl `evalSync` on the
same context (e.g. `items[.price <= 2].name` → `"apple"`, because
drilling into a filtered array takes element 0 per Jexl semantics).

## Context corpus

`tools/corpus_ctx.txt` — 29 lines of `expr<TAB>{json-context}` pairs
(README-style use cases: nested names, assoc filtering, math on
context vars, null/undefined lookups, empty-array filters, object
literal with context refs). Both runners parse the per-line context;
29/29 identical to real Jexl.

Known intentional divergence (not in the diff corpora, see
`tools/divergence.txt` and docs/parity-contract.md §4): Engine throws a
TypeError for `arr[.f == x].prop` when the filtered array is empty
(its README example `assoc[.first == "Lana"].last` without a context
crashes there); mbel returns undefined.
