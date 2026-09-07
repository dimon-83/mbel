# Changelog

All notable changes to mbel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is SemVer
(see AGENTS.md "Version management and releases").

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
