# Changelog

All notable changes to mbel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is SemVer
(see AGENTS.md "Version management and releases").

## [Unreleased]

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
  is bounded by the host stack (budgets restart per call).
- **Playground custom-functions card**: loads a functions file
  (format v1: `{version, functions:[{name, params?, body,
  description?}], env?}`) via file picker/editor, renders resolved
  signatures as chips, persists in localStorage, restores on reload.
  New wasm exports `eval_with_functions(code, env, funcs_json, mode,
  engine)` (mode ∈ eval/checked/legacy; env doubles as the functions'
  default bindings) and `describe_functions(funcs_json)`; the
  `env` key is a page-level example environment filled into the env
  box on load. Example file `playground/functions.example.json`.
- Test suite grown to 228 tests × 3 targets (engine-level userfunc
  suites on both engines: calls, pipes, strict-mode whitelist, env
  fallback, recursion, mutual references, validation error paths).

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
