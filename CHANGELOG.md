# Changelog

All notable changes to mbel are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is SemVer
(see AGENTS.md "Version management and releases").

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
