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
