# Changelog

All notable changes to mbel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is SemVer
(see AGENTS.md "Version management and releases").

## [Unreleased]

### Added

- **More RE2 constructs now translate instead of being cut.** `\xHH` and
  `\x{H…}` are code-point escapes in RE2 and core spells those
  `\u00HH`/`\u{H…}`; `(?P<name>…)` is Go's other named-group spelling and
  is normalized to `(?<name>…)`; `\Q…\E` is rewritten as escaped literal
  text (a missing `\E` quotes to the end, as in RE2). `\x` works inside a
  character class too, including as a range end. The documented cut list
  shrinks to `\p{…}`, `(?m)`, class-internal `\D`/`\W`/`\S`, in-class
  `\Q…\E`, `(?U)` and `(?-i)` in an active `(?i)` scope. All of it is
  covered by the Go differential corpus, now 122 cases.
- **Dialect-specific `len`/`type`** — the standard dialect now reports
  expr's names and counting: `type(5.0)` is `"float"` (was `"number"`) and
  `len('👍')` is `1` code point (was 2 UTF-16 units). The front end lowers
  these two calls to a dialect-specific implementation, so the classic
  dialect keeps the JS answers (`"number"`, UTF-16 units) that its suites
  lock. This un-skips transcribed upstream rows 049/050: the want table is
  now 153 transcribed + 14 documented skips.
- **The checker type-checks array membership like expr.** Compile mode
  reports `cannot use int as type string in array` (with expr's
  `msg (L:C)` + source line + caret layout) for `1 in ["a"]`. Numbers stay
  comparable across int/float, `nil` is comparable with anything, and a
  heterogeneous array literal is typed as a plain array rather than
  rejected — which is what expr does: container literals are *typed*, not
  required to be homogeneous.
- **The checker type-checks map keys like expr.** Compile mode reports
  `cannot use int as type string in map key` for `1 in {a: 1}` (and the same
  for float/bool/nil members). That test is expr's `AssignableTo`, not
  `ComparableTo`: `nil` is comparable with everything but not assignable to a
  string key, which is why `nil in [1]` is fine while `nil in {a: 1}` is a
  compile error.
- **Resource-gate observability** — `Engine::budget_stats()` and
  `Engine::reset_budget_stats()`. The budget failure messages are a locked
  contract (`expression is too large (more than N nodes)`, …), so they gain
  no text; the counters are where the outcome of the gate becomes visible.
  Each counter is `(reason, count)` in first-hit order, with `reason` one of
  `nodes`, `nesting`, `depth`, `steps`, `memory`, `value_nesting`,
  `flatten_depth`. Ordinary errors (syntax, type, unknown name) are not
  counted, and the snapshot is a copy rather than live state. Counters are
  incremented by per-stage guards around the parse and evaluation stages of
  each entry point, so one failure counts once — including the expr
  front-end path, which the tests pin down.
- **`Engine::clear_caches()`** — drops the compiled `matches` pattern cache,
  so an embedder fed unbounded dynamic patterns can reclaim that memory on
  its own schedule instead of waiting for the engine to be dropped.
- **CI gate** (`.github/workflows/ci.yml`) — the three-target matrix
  (wasm-gc, js, native) now runs on every push to `main` and every pull
  request. The repository previously had no automated test gate at all.

### Changed

- The pre-commit hook now runs `moon check` **and** `moon test` (it ran only
  `moon check`), and `core.hooksPath` is documented as a required per-clone
  step. Previously the hook file existed but nothing installed it, so it
  never ran on any commit. `moon fmt` is deliberately excluded: the pinned
  toolchain's formatter rewrites unrelated files.
- `docs/{en,zh}/environment.md` document two boundaries of the gate that were
  previously implicit: host-registered callbacks (`add_function` /
  `add_transform` / `add_binary_op`) run outside the budget, and
  `max_steps` is an allocation budget rather than a CPU budget.

### Fixed

- **The classic lexer cut astral characters out of string literals.**
  `unquote` stripped the quotes with `str[1:n - 1]`, where `n` counts code
  points but string slicing indexes UTF-16 units — so `"a👍b"` decoded to
  `a` plus a lone surrogate, losing everything after the character, and
  `len("👍")` was `0`. The quotes are now stripped by code point; the
  classic dialect reports `len("a👍b") == 4` and `len("👍") == 2`, matching
  JS.
- **Time and duration arithmetic produced meaningless numbers.**
  `now()` and `date()` returned milliseconds while `duration()` returned
  nanoseconds, and `+`/`-` simply added the raw values, so
  `date("2024-01-01") + duration("24h")` returned `88104067200000` and
  `now() - duration("1h")` returned a negative number — silently, with no
  error. All three now evaluate to **int64 nanoseconds** (the same unit as
  Go's `UnixNano`/`Duration`), which makes time and duration arithmetic
  exact int64 addition: `date("2024-01-01") + duration("24h")` equals
  `date("2024-01-02")` exactly. int64 rather than double because
  nanoseconds since the epoch exceed 2^53, so a double representation
  would make timestamps under ~256 ns apart compare equal. `duration()`
  keeps its nanosecond values, so the transcribed expr want-table rows
  (r102–r113) still match.
- **`in` used a stricter equality than `==`.** Array membership matched
  elements with `strict_eq`, so `1 in [1.0]` was `false` while `1 == 1.0`
  was `true` — an internal contradiction the checker did not catch,
  because expr accepts the expression (numbers are comparable). Membership
  now uses the operator's equality under the typed value model, while the
  dynamic/legacy path keeps `strict_eq` so no legacy behaviour moves.
  Comparison stays exact int64 (`9007199254740993 in [9007199254740992]`
  is `false`).
- **`in` now tests map keys.** `"foo" in {foo: 0}` returned `false` because
  `in_op` only handled strings and arrays; it now checks key membership for
  objects, matching expr and JS object `in` (so the legacy dialect gains the
  same answer rather than a divergent one — the legacy corpus has no object
  `in` case). Only a string member can match: mbel map keys are strings, and
  the checked entry rejects a non-string member outright, so coercing numbers
  to keys would invent matches the checker forbids. This un-skips the
  transcribed upstream row 026 (`1 in [1, 2, 3] && "foo" in {foo: 0, bar: 1}
  && "Bar" in Foo`): the want table is now 151 transcribed + 16 documented
  skips.
- **The `matches` pattern cache is now capacity-bounded.** It grew for the
  lifetime of an engine: every distinct pattern and its compiled program
  were retained forever, and the lookup is a linear scan, so both memory and
  per-match time degraded with the number of distinct patterns seen.
  Successful patterns are capped at 256 (`regex_cache_capacity()`),
  remembered failures at 64 (`regex_failed_capacity()`); when full, the
  oldest half is dropped so inserts stay amortized O(1).
- **`sort` returned integer arrays unsorted in the standard dialect.**
  `sort_values` classified values by matching `NumVal` and `StrVal`, so the
  `IntVal` elements the standard dialect produces for integer literals and
  integer arithmetic fell through to the "mixed array, no total order"
  branch and came back in input order — silently, with no error
  (`sort([3,1,2])` → `[3,1,2]`). `IntVal` now counts as numeric, and two
  `IntVal`s compare as exact int64 so ordering above 2^53 is not lost
  through the double fallback. Floats, strings and mixed numeric arrays are
  unchanged.
- **`get` ignored integer indices in the standard dialect.** Its array
  branch matched `@ast.NumVal(d)` only, so `get([3,1,2], 1)` returned the
  fallback (`nil`) instead of the element. Both integer kinds are handled
  now; out-of-range and negative indices still fall back.

  `sort`, `get` and the membership equality were all invisible to the
  existing tests because the only coverage drove those builtins through the
  **legacy** dialect, whose lexer produces nothing but `NumVal`.
  `engine_test/typed_builtin_test.mbt` exercises them through `eval_expr` on
  both engines with explicit value kinds, and AGENTS.md records the rule.


## [0.3.5] — 2026-10-14

### Fixed

- **`matches` now implements RE2 regex semantics.** `grammar_regex_match`
  called `@string.Regex::string`, which builds a *literal* matcher — the
  pattern was matched as plain text — so `matches` behaved like
  `contains` (`"hello" matches "^h.*o$"` was `false`). It now compiles a
  real pattern through the core parser, and a malformed pattern raises
  instead of silently returning `false`. That error path already existed
  in the code but was unreachable, which is why this reads as a
  wrong-constructor bug rather than a deliberate cut.
- **Pattern errors carry the engine's own diagnostic.** The failure path
  discarded it and reported a bare `invalid regex: <pattern>`; the
  message now names the offending construct, and the failure text is
  cached so a repeated evaluation reports exactly the same message on
  both engines.

### Added

- **RE2 → core translation layer** (`evaluator/regex_translate.mbt`), so
  the RE2 constructs with a core equivalent behave as in Go: class
  shorthands (`\d \D \w \W`, and `\s \S` translated to `[\t\n\f\r ]` —
  Go's `\s` excludes `\v` while core's `[[:space:]]` includes it), `.`
  (any character except newline; `(?s)` for dot-all), a leading or
  trailing `-`/`]` in a character class, bare `(?i)`/`(?s)` flags, and
  named groups.
- **Go differential harness for `matches`**: `tools/regex_corpus.txt`
  (106 cases), `tools/regex_oracle.go` (Go's `regexp`, i.e. RE2 — the
  engine expr itself uses), `tools/gen_regex_mbt.py` (freezes the
  verdicts) and `engine_test/regex_re2_test.mbt` (asserts mbel agrees on
  every row, on Walk and Vm). 106/106 identical.

### Changed

- The documentation claim that the MoonBit core regex is "literal-only"
  was wrong, and so was "the remaining gaps are `\d`/`.`/`(?i)`" — those
  are now translated. `docs/en/language-definition.md`,
  `docs/zh/language-definition.md`, `docs/expr-gap-analysis.md`,
  `docs/coverage-vs-expr.md`, `docs/review-roadmap-2026-09-06.md`,
  `tools/README.md` and the README state the supported surface and the
  exact cuts.
- TestExpr want-table rows 033/034 — the two rows skipped as a "regex
  cut" — are now transcribed and asserted on both engines (150
  transcribed + 17 documented skips). `builtin_test` gains real-regex
  cases plus an invalid-pattern case, and the VM parity suite asserts
  regex values and the invalid-pattern error message agree across
  engines.
- **API:** `@evaluator.Grammar`'s `regex_failed` cache field changed type
  from `Array[String]` to `Array[(String, String)]` — pattern plus the
  message to re-raise — so a failed pattern keeps one consistent error
  text. `Grammar` is `pub(all)`, so this is a source-level change for code
  that builds a grammar literal; `default_grammar()` and the engine entry
  points are unaffected.

### Documented cuts

`matches` rejects, with an actionable `invalid regex: …` message rather
than a silent wrong answer: `\p{…}`/`\P{…}` Unicode properties, `(?m)`
multiline, `\D`/`\W`/`\S` inside a character class, `\Q…\E`, `\xHH`,
`(?P<name>…)`, `(?U)`, and switching `(?i)` back off inside an active
`(?i)` scope.

## [0.3.4] — 2026-10-11

### Added

- `THIRD_PARTY_NOTICES.md`: the MIT copyright and full license text for
  the expr-lang/expr test fixtures transcribed into
  `expr_test/want_table_test.mbt` and `expr_test/checker_ok_test.mbt`,
  with the covered scope and the exact upstream revision
  (`4b31df3`, tag v1.17.8 plus eight commits). Both files now declare
  `SPDX-License-Identifier: Apache-2.0 AND MIT` and point at the notice;
  the surrounding MoonBit harness remains Apache-2.0. The root file is
  included in the `moon package` source package.

### Changed

- `docs/coverage-vs-expr.md` §6.3 records the transcription provenance;
  the earlier "v1.17.8, 167 rows" note conflated the tag (163 TestExpr
  rows) with the transcribed revision.
- Generated repo-local diagrams (`architecture.html`,
  `architecture-dialect-engine.html`) are gitignored so they stay out of
  the published source package.

## [0.3.3] — 2026-09-10

Documentation patch: the user-facing docs are synced to the 0.3.2
feature set (no code changes; the mooncakes package page picks up the
current README with this release).

### Changed

- `docs/{zh,en}/functions.md`: the expression-defined-function page now
  describes the 256-level instance-wide recursion cap (the
  "bounded only by the host stack" note predated the hardening) and
  calls the playground UI a drawer, matching the shipped page.
- `README`: the playground section lists `eval_with_functions(code,
  env, funcs_json, mode, engine)` and `describe_functions(funcs_json)`
  with their signatures, mentions the custom-functions drawer, and
  documents the stateless-wasm persistence contract for embedders.
- `docs/{zh,en}/language-definition.md`: the errors/budgets section
  adds the 0.3.2 resource guards (source-length cap, user-function
  recursion 256, deep nesting 1024, range ≤ 1e6 elements, repeat output
  ≤ 1e6 chars) and links the full table in "Security model".

## [0.3.2] — 2026-09-09

Custom user-function extension (expression-defined functions, JSON
function files, playground drawer UI) plus the security hardening pass
(resource-exhaustion guards from the sandbox assessment).

### Added

- **Expression-defined user functions**: register functions whose body
  is an expression source string — `Engine::add_expression_functions(defs,
  defaults)` (both pools, so `f(x)`, standard pipes and classic pipes
  all resolve), standalone `user_function_params(name, body)`, and the
  `UserFunctionDef { name, params?, body }` shape. `params` may be
  omitted: free identifiers are auto-extracted from the (compiled,
  folded) body in first-appearance order. `defaults` (typically the
  evaluation env) provides fallback bindings for unpassed parameters;
  explicit arguments win. Names are validated atomically (identifiers,
  not keywords/aggregates/`$env`, unique); ordinary builtins may be
  overridden via upsert. Vm bytecode is cached per function; recursion
  is capped by an instance-wide depth counter (see Security).
- **Playground custom functions**: a 🧩 drawer (right-side popup, opened
  from the control row) loads a functions file (format v1:
  `{version, functions:[{name, params?, body, description?}], env?}`)
  via file picker or a pretty-printed editor, renders resolved
  signatures as chips and persists in localStorage (restored on
  reload); the file's `env` example fills the environment box. New wasm
  exports `eval_with_functions(code, env, funcs_json, mode, engine)`
  (mode ∈ eval/checked/legacy; env doubles as the functions' default
  bindings) and `describe_functions(funcs_json)`. Layout regrouped:
  dialect/engine selectors and buttons span one row above the
  expression; the env JSON is a large pretty-printed textarea; quick
  examples and the advanced view stack under the result card. Example
  file `playground/functions.example.json`.
- Engine-level userfunc suites on both engines: calls, pipes,
  strict-mode whitelist, env fallback, recursion, mutual references and
  validation error paths.

### Security (resource-exhaustion hardening)

- **User-function recursion cap**: expression-defined functions are
  bounded by an instance-wide 256-level call-depth counter (direct,
  mutual, and cross-batch recursion), raising
  `function call depth exceeded (more than 256 levels)` instead of
  overflowing the host stack.
- **Range span computed in Int64**: `(-2147483648)..2147483647` used to
  wrap the 32-bit `hi - lo` check and attempt a ~2^32-push materialization;
  the 1e6-element cap now holds for extreme bounds too.
- **Source-length cap**: both dialect entries reject input longer than
  max_nodes × 16 characters before tokenizing (a single huge string
  literal is one token, so node budgets could not bound lexer memory).
- **repeat output cap**: the output size (len × count) is capped at 1e6
  characters, closing the `repeat(long, 1e6)` amplification.
- **Deep-nesting guards**: structural equality (`==`/`!=`/`in`),
  `toJSON` and flatten reject or truncate values nested deeper than
  1024 levels (`value nesting too deep (more than 1024 levels)`); the
  flatten guard moved below the smallest host stack; array
  stringification truncates with "…" instead of recursing off the
  stack. Core-json's own 1024 parser depth already bounds `fromJSON`.
- **Playground**: the one dynamic `innerHTML` (WASM load error message)
  now renders via textContent nodes.
- Test suite grown to 235 tests × 3 targets; every guard is asserted on
  both engines and all three targets (native/wasm-gc/js).

## [0.3.1] — 2026-09-07

Stage-4 close-out patch: the remaining 4.4 items landed, together with
playground tooling and de-originated user-facing naming.

### Added
- **Byte strings evaluate as `BytesVal`** (4.4.3 close-out, expr
  `[]byte` parity): `b"…"`/`B'…'` values now evaluate instead of
  raising; typed comparison/`type()`/`toJSON` cover bytes.
- **Position-carrying Compile-mode errors** (4.4.4 close-out): checker
  errors carry expr's FileError layout — `msg (L:C)` plus the source
  line and a caret column.
- **Official test-table transcription** (4.4 gate acceptance): expr's
  TestExpr and checker TestCheck suites transcribed into the safety
  net (want-table harness in expr_test).
- **Playground execution-engine selector**: `eval_expr`/`eval_jexl`/
  `eval_checked` exports take an `engine` argument (`"walk"`/`"vm"`),
  so every dialect/mode runs on the walk-tree interpreter or the
  bytecode VM; quick examples grown to 18 (incl. a multi-line
  let + if/else + `all()` demo); elapsed time reported in µs.
- Options audit (4.4.5 close-out): env-whitelist/AsBool alignment
  decisions recorded (docs/coverage-vs-expr.md §6.2 item 8).

### Fixed
- Playground timing read 0 or 1 000 000 ns on hosts whose
  `performance.now()` is coarsened to 1 ms — single-shot measurement
  replaced by an amplified ~40 ms window average, then displayed in
  µs (auto-switching to ms for heavy expressions).

### Changed
- User-facing terminology de-originated: **standard dialect** (Eval /
  Compile modes) and **classic dialect (legacy)** replace the
  porting-source names in the playground, README, and the en/zh user
  manuals (one reference-baseline note per docs set); README roadmap
  refreshed to the 4.4 close-out list. API identifiers
  (`Engine::eval_expr` etc.) are unchanged.
- Test suite grown to 215 tests × 3 targets (native/wasm-gc/js).

## [0.3.0] — 2026-09-07


Stage-4 typed milestone: typed value model, static checker with a
strict Compile-mode entry, and a locked three-dialect API; the expr
front end now matches expr-lang (v1.17.8) semantics on typed
operations, and a browser playground ships with the module.

### Added
- **Typed value model (4.4.3)**: `IntVal(Int64)` values — expr integer
  literals lower to `IntVal` (out-of-int64 is a parse error); shared
  operators follow expr runtime typing (int-preserving `+ - *` with Go
  wraparound, int/float widening, `/` always float without division-by-
  zero errors, `%` integer-only with "integer divide by zero", unary
  minus type-preserving, cross-type `==` false and ordering/mixed `+`
  raise "invalid operation"); typed builtin/aggregate returns
  (`len`/`count`/`int()`/`sum` etc.), exact `toJSON` (int64 full
  precision, NaN/Inf → null).
- **Static checker + strict entry (4.4.4)**: `Engine::eval_expr_checked`
  (Compile mode) — Nature inference, operator type rules, let-binding
  scoping, homogeneous container elements, core builtin argument
  checks, and a strict env whitelist ("unknown name x"); Eval mode
  stays dynamic (typed runtime errors only).
- **Dialect/mode API locked (4.4.5 surface)**: three documented
  entries — `Engine::eval` (Jexl legacy, JS semantics, corpus-locked),
  `Engine::eval_expr` (expr Eval mode), `Engine::eval_expr_checked`
  (expr Compile mode) — all running on Walk and Vm under the same
  budgets (docs/coverage-vs-expr.md §5, README "Dialects and
  evaluation modes").
- **Program disassembler (4.3)**: `evaluator.disassemble` prints every
  VM instruction with decoded constants and jump targets.
- **Browser playground (`playground/`)**: test page with a wasm-gc
  entry package exporting `eval_expr`/`eval_jexl`/`eval_checked`/
  `disassemble`/`dump_ast` (js-string builtins string interop, no glue
  code); three dialect modes labeled (expr recommended, jexl legacy),
  real AST/bytecode/debug views.
- **English + Chinese user docs**: getting-started, language
  definition, functions, visitor, patch; docs/ coverage matrix and gap
  analysis updated.

### Fixed
- Expr front end (verified against expr-lang v1.17.8): pipes into
  predicate aggregates parse their first explicit argument in predicate
  context (`tweets | filter(.Content contains "Hello") | map(.User) |
  first()`); Jexl bracket predicates `items[.price <= 2]` accepted as a
  documented compatibility extension (lowered to the legacy relative
  FilterExpression on both engines); pointers `#`/`#index`/`#acc` are
  predicate-only (parse error elsewhere); a pipe's right side must be a
  parenthesized call, matching expr.
- Vm relative-filter loop now maintains the typed pointer slots
  (`#`/`#index`) like the Walk per-element evaluator — element filters
  ran on Walk but read nil slots on Vm; `#index` is the real position on
  both engines.
- Playground engine instances register the CLI demo transforms
  (dbl/first/concatWith) so the legacy `|` pipe behaves like the docs
  and the corpus driver.

### Changed
- Test suite grown to 207 tests × 3 targets (native/wasm-gc/js), each
  expr case asserting Walk/Vm parity.
- Remaining stage-4 items tracked in docs/coverage-vs-expr.md §6.2:
  byte-string evaluation, position-carrying checker errors, legacy
  package physical split, Options alignment (env whitelist/AsBool),
  and the expr TestExpr 167-line want-table transcription (4.4 gate).

## [0.2.0] — 2026-09-06

Stage-4 expr catch-up: syntax layer complete, both engines genuinely
parity-tested.

### Added
- **expr front-end package (`expr/`)**: expr-lang (v1.17.8) dialect
  lexer + Pratt parser + lower bridge to the legacy AST — full literal
  family (hex/oct/bin/underscores/exponents/`.5`, raw backtick and
  byte strings, expr escape set incl. `\u{…}`/octal), comments,
  keyword operators (`in`/`matches`/`contains`/`startsWith`/
  `endsWith` + `not`-suffix forms), chained comparisons, `??` mixing
  guard, `**`/`^` right-assoc power with unary precedence parity
  (`-2**2 = -(2**2)`), `?.`/`?.[`, slices, if/else blocks, `let` +
  `;` sequences, `{…}` predicates with `#`/`#index`/`#acc`, `$env`,
  pipes.
- **Evaluation of the new syntax on both engines**: lexical scope
  (locals in the walk evaluator; VM `OP_SLICE`/`OP_LOADLOCAL`/
  `OP_ADDLOCAL`/`OP_POPLOCAL`/`OP_ENV`, now 26 opcodes), slice
  semantics, `$env` = root context, unary minus, nil-safe string
  operators, `Engine::eval_expr`/`eval_ast` API.
- **Safety-budget parity**: the Vm engine enforces the `max_depth`
  eval-depth budget (per-instruction source-AST depths); the expr
  front-end parse applies `max_nodes` and recursion/depth guards.
- Real dual-engine performance & stability measurements
  (docs/coverage-vs-expr.md §7) and version-management rules
  (AGENTS.md).

### Fixed
- Vm engine never dispatched end-to-end since its introduction —
  restored, exposing and fixing genuine dispatch bugs (missing
  `OP_LOADSLOT` arm, eager `&&`/`||`/`??` operand compilation, elvis
  result loss, `OP_FILTERBEGIN/END` pc semantics, missing-branch
  runtime raise via `CRaise`). Early "Vm" measurements (perf report,
  README tables) were tree-walk data and are marked invalid.
- Byte-string lexing (`b"…"` mis-lexed as an identifier), escape
  validation, `#age`-style unknown pointers now compile errors.

### Changed
- 15 predicate aggregates (map/filter/count/reduce/…) with typed slots
  on both engines; `{}` predicate blocks accepted.
- Test suite grown to 188 tests × 3 targets (native/wasm-gc/js).

## [0.1.0] — 2026-09-05

Initial release candidate: full Jexl port with the dual-engine
bytecode VM, safety budgets, builtin library, and JSON-context CLI.

### Added
- Jexl-compatible dynamic evaluation (tree-walk reference engine),
  3,360+ expression differential corpus against real Jexl.
- Bytecode VM as a second engine (Walk/Vm switchable), constant
  folding, parallel-array instruction encoding, native filter loops.
- Safety budgets (node/nesting limits, eval depth, shared step
  budget), expr-style builtins (57/64 coverage), `matches`/`..`/`??`
  operators, predicate aggregates with `#`/`#index`/`#acc` slots.
- CLI expression runner with JSON contexts; module renamed to
  `dimon-83/mbel` (`engine` package).
