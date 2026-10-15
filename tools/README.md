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

## Optimizer sample (behavioural)

- `tools/gen_optimizer_sample.py` — reads the reference checkout's
  `optimizer/optimizer_test.go` `TestOptimize` table (43 inputs, each with
  the value expr produces *with* its optimizer passes) and freezes it into
  `expr_test/optimizer_sample_data_test.mbt`. Honour `EXPR_SRC` to point at
  the checkout; the default is the sibling `../expr`.
- `expr_test/optimizer_sample_test.mbt` — evaluates the same inputs on both
  engines with env `{a: 1, b: 2, c: 3}` and asserts the same results. mbel
  has constant folding only, so this pins the property that has to hold
  without the passes: identical values. 43/43.

## Unicode classes for `\p{…}`

- `tools/unicode_oracle/` — emits `evaluator/unicode_classes.mbt` from Go's
  own `unicode` package (general categories and scripts, 212 names). expr's
  `\p{…}` is Go's regexp, so taking the tables from Go makes agreement a
  property of the build rather than of matching Unicode versions.
  Run: `cd tools/unicode_oracle && go run . ../../evaluator/unicode_classes.mbt`.

## Time differential corpus (`date`)

- `tools/time_corpus.txt` — `date()` inputs.
- `tools/time_oracle/` — evaluates each input exactly as expr's `date()`
  does (the 7-layout scan with Go's `time.Parse`) and prints int64
  `UnixNano`, or `ERR`.
- `tools/gen_time_mbt.py` — freezes that into
  `expr_test/time_want_data_test.mbt`; `expr_test/time_want_test.mbt` runs
  the same inputs through mbel on both engines. 27 cases, including
  RFC3339 numeric offsets, fractional seconds, leap years and the
  RFC822/850/1123 layouts.

## Parser differential corpus (`TestParse`)

- `tools/parse_corpus.txt` — the 105 inputs of upstream
  `parser/parser_test.go`'s `TestParse` table.
- `tools/parse_oracle/` — a small Go module that parses each input with the
  *reference* expr parser and prints the AST in mbel's `dump()` convention
  (`go run . ../../tools/parse_corpus.txt`). It `replace`s
  `github.com/expr-lang/expr` with a local checkout; expr has no external
  dependencies, so it resolves offline. Set `GOCACHE` to a workspace path if
  the sandbox forbids the default cache location.
- `tools/gen_parse_mbt.py` — freezes the oracle output into
  `expr_test/parse_want_data_test.mbt`.
- `expr_test/parse_want_test.mbt` — asserts mbel's parser produces exactly
  that shape. Currently 96 of 105 rows match; the 9 remaining are listed
  with their reason in `parse_want_skips()`.

Unlike the regex corpus this compares *tree shape*, not values, so it also
pins the node names mbel's own tests rely on.

## Regex differential corpus (`matches`)

`tools/regex_corpus.txt` — 106 `pattern<TAB>subject` cases for the
`matches` operator. Both fields use one escape convention (`\n \t \r \f
\v \\ \"` decoded, everything else literal), so a regex escape like `\d`
is written `\\d`.

- `tools/regex_oracle.go` — the Go side: evaluates every case with Go's
  `regexp` package (RE2, the engine expr-lang itself uses) and prints
  `match` / `no match` / `error`. Only that distinction is compared;
  Go's and the core engine's error *text* differ by design.
- `tools/gen_regex_mbt.py` — runs the oracle and freezes the verdicts
  into `engine_test/regex_re2_data_test.mbt`.
- `engine_test/regex_re2_test.mbt` — the mbel side: asserts `matches`
  produces the same verdict on every row, on BOTH engines. The pattern is
  bound through the environment (`s matches p`), so no string-literal
  escaping sits between the corpus and the regex engine.

    python3 tools/gen_regex_mbt.py   # runs Go, regenerates the table
    moon test -p engine_test         # asserts mbel agrees

A mismatch names the offending case and engine. Verified 2026-10-14:
106/106 identical to Go (go1.27.0) on Walk and Vm.

Known cuts are deliberately NOT in this corpus — they are covered by
`evaluator/regex_translate_wbtest.mbt` and documented in
docs/expr-gap-analysis.md: `\p{…}`, `(?m)`, `\D`/`\W`/`\S` inside a
character class, `\Q…\E`, `\xHH`, `(?P<…>)`, `(?U)`, and turning `(?i)`
back off inside an active `(?i)` scope.
