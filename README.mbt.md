# mbel — Expression Engine for MoonBit

mbel is a native MoonBit expression-language engine that started as a
full port of [Jexl](https://github.com/TomFrost/Jexl) and is evolving,
stage by stage, toward the semantic richness of
[expr-lang/expr](https://github.com/expr-lang/expr). The end goal is a
safe, reliable, high-performance expression engine suited to rules
engines, dynamic configuration, low-code platforms, and workflow
orchestration.

Current status: the complete **Jexl language and API surface** is
ported and verified byte-for-byte against the real Jexl runtime;
expr-style resource budgets, a builtin function library, `??`/`..`/
`matches` operators, and compile-time constant folding are in place.
The expr-alignment roadmap is tracked in
[docs/expr-gap-analysis.md](docs/expr-gap-analysis.md).

## Quick start (CLI)

The command-line runner evaluates expressions with an optional JSON
context:

```text
$ moon run cmd/main -- "1 + 2 * 3"
7

$ moon run cmd/main -- "'hello' + ' ' + 'world'"
"hello world"

$ moon run cmd/main -- "6+x*2>10 ? 'big' : 'small'" '{"x": 3}'
"big"

$ moon run cmd/main -- "age * (3 - 1)" '{"age": 36}'
72

$ moon run cmd/main -- 'assoc[.first == "Lana"].last' \
  '{"assoc": [{"first": "Lana", "last": "Kane"}, {"first": "Cyril", "last": "Figgis"}]}'
"Kane"

$ moon run cmd/main -- "user.name + ' scored ' + (score * 10)" \
  '{"user": {"name": "alice"}, "score": 8.5}'
"alice scored 85"

$ moon run cmd/main -- "items[.price <= 2].name" \
  '{"items": [{"name": "apple", "price": 1.5}, {"name": "pear", "price": 3}]}'
"apple"
```

expr-style predicate aggregates work on both engines:

```text
$ moon run cmd/main -- "map(nums, # * 2)" '{"nums": [1, 2, 3, 4, 5]}'
[2,4,6,8,10]

$ moon run cmd/main -- "filter(users, .age >= 18)[0].name" \
  '{"users": [{"name": "Alice", "age": 30}, {"name": "Bob", "age": 15}]}'
"Alice"

$ moon run cmd/main -- "sum(1..100)"
5050

$ moon run cmd/main -- "count(users, .age >= 18)" \
  '{"users": [{"name": "Alice", "age": 30}, {"name": "Bob", "age": 15}, {"name": "Cyx", "age": 24}]}'
2

$ moon run cmd/main -- "groupBy(nums, # % 2)" '{"nums": [1, 2, 3, 4, 5]}'
{"1":[1,3,5],"0":[2,4]}

$ moon run cmd/main -- "reduce(nums, #acc + #, 100)" '{"nums": [1, 2, 3, 4, 5]}'
115
```

Contexts are JSON: `null` → `nil`, numbers and nested objects/arrays
work as expected. A few demo transforms (`dbl`, `first`,
`concatWith`) are registered in the CLI, so pipes work too:

```text
$ moon run cmd/main -- "[1,2,3]|first"
1

$ moon run cmd/main -- "5|dbl|dbl"
20
```

## User documentation

Mirroring the expr-lang docs, in English and Chinese:

- English: docs/en (getting-started, environment & configuration,
  custom functions, visitor, patch, language definition)
- 中文: docs/zh(快速上手、环境与配置、自定义函数、visitor、patch、语言定义)

Internal/dev docs (parity contract, coverage matrix, gap analysis,
perf report) live in docs/.

## Using mbel as a library

The engine is organized into small packages — `grammar`, `lexer`,
`parser`, `ast`, `evaluator`, and `engine` (the top-level API):

```moonbit nocheck
import {
  "dimon-83/mbel/ast",
  "dimon-83/mbel/evaluator",
  "dimon-83/mbel/engine",
}

let inst = @engine.new()

// Evaluate against a context
let ctx = @ast.ObjectVal([
  ("user", @ast.ObjectVal([("age", @ast.NumVal(36.0))])),
])
let v = try {
  @engine.Engine::eval(inst, "user.age > 18 ? 'adult' : 'minor'", ctx)
} catch {
  @engine.EngineErr(msg) => abort(msg)
} // StrVal("adult")

// Register transforms / functions / operators
@engine.Engine::add_transform(
  inst,
  "dbl",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
  },
)
let doubled = try {
  @engine.Engine::eval(inst, "21|dbl", @ast.ObjectVal([]))
} catch {
  @engine.EngineErr(msg) => abort(msg)
} // NumVal(42.0)

// expr-style resource budgets: nodes at parse time, depth + steps at
// eval time (0 disables a limit)
@engine.Engine::set_limits(inst, 10000, 10000, 1000000)
```

### Choosing an engine: Walk (tree-walk) or Vm (bytecode)

mbel ships two execution engines that share one semantic layer, so
they produce identical results and identical error messages (asserted
by an internal parity suite over the whole differential corpus). Pick
the engine per instance:

```moonbit nocheck
// Walk — the reference tree-walk interpreter (default)
let walk_inst = @engine.new()
@engine.Engine::set_engine(walk_inst, Walk)

// Vm — compiles the (constant-folded) AST to bytecode once per
// Expression, caches the program, and runs a 26-opcode stack machine
let vm_inst = @engine.new()
@engine.Engine::set_engine(vm_inst, Vm)

// Both engines run the same expressions, transforms, and budgets
let ctx = @ast.ObjectVal([("x", @ast.NumVal(3.0))])
let a = @engine.Engine::eval(walk_inst, "6+x*2>10 ? 'big' : 'small'", ctx)
let b = @engine.Engine::eval(vm_inst, "6+x*2>10 ? 'big' : 'small'", ctx)
// value_equal(a, b) — always true; vm_parity tests enforce it

// The CLI can run either engine too:
//   moon run cmd/main -- "2+2*3" "" vm
```

Engine notes: the Vm mode's value is the compiled `Program` cached on
each `Expression` (re-evaluations skip compilation entirely);
`FilterExpression` subtrees and manual-eval (lazy) operators are
executed by tree-walk callbacks that share the step budget, so
budgets behave identically on both engines.

### Dialects and evaluation modes (stage 4.4.5)

The engine separates the legacy Jexl dialect from the expr-lang
front-end, and expr's two execution modes:

- `Engine::eval(inst, src, ctx)` — **Jexl legacy dialect**: the
  original Jexl grammar, JS dynamic semantics (numbers are doubles,
  loose `==`, substring `in`), locked by the Jexl differential corpus
  and the legacy test suites.
- `Engine::eval_expr(inst, src, ctx)` — **expr-lang front end, Eval
  mode** (expr's `expr.Eval`): full expr syntax, typed runtime
  semantics — integer literals and integer arithmetic are typed
  `IntVal` (int64, Go wrap), `/` is always float division
  (`7/2 = 3.5`, `1/0 = +Inf`), `%` is integer-only, cross-kind
  comparisons/`+` raise `invalid operation: ...` at runtime. No
  static checks, exactly like expr's Eval.
- `Engine::eval_expr_checked(inst, src, ctx)` — **expr front end,
  Compile mode** (expr's `expr.Compile`): runs the stage-4.4.4
  phase-1 checker first; statically-known type violations surface
  expr's compile-mode messages (`invalid operation: + (mismatched
  types int and string)`, `non-bool expression (type int) used as
  condition`).

All three entries run on either engine (Walk or Vm) with identical
results, and all honor `set_limits` budgets (the expr front end
applies `max_nodes` at parse time).

## Current capabilities (Jexl parity)

- **Literals**: numbers, single/double-quoted strings with escapes,
  booleans; **array** and **object** literals (`{a: 1, "b": 2}`).
- **Operators**: arithmetic `+ - * / // % ^`, comparison
  `== != > >= < <=` with JavaScript coercion semantics, logic
  `&& || !`, `in` (substring / array membership), ternary `?:`
  including the `a ?: b` form.
- **Access**: dotted chains `a.b.c`, computed keys `obj["k"]`, array
  indexing, **relative filters** `arr[.x == 1]` with element-0 drill
  semantics, transforms via `|` pipes (`foo|toUpper`), and custom
  function calls `f(x)`.
- **Extensibility**: `add_transform`, `add_function`, `add_binary_op`
  (incl. manual/lazy operand evaluation), `add_unary_op`, `remove_op`,
  `get_transform` / `get_function` — each Jexl instance owns an
  isolated grammar (elements can be added and removed per instance).
- **Safety**: configurable node limit (default 10 000), sub-expression
  nesting limit, eval depth and shared step budgets — the expr-style
  protections that plain Jexl lacks.
- **Verification**: 111 MoonBit tests mirror the Jexl Jest suites
  (lexer/parser/evaluator/API), and a differential harness runs 3 300+
  expressions (hand-written corpus, generated fuzz, JSON-context
  corpus) through both mbel and the real Jexl, requiring byte-identical
  output (`tools/`, `docs/parity-contract.md`).

## expr-lang builtins already available

Stage 4.2 seeded the engine with expr-style builtins (registered on
every instance, callable as plain functions): `abs ceil floor round
max min mean median`, `trim trimPrefix trimSuffix upper lower split
splitAfter replace repeat join indexOf lastIndexOf hasPrefix hasSuffix
string`, `len first last get take keys values reverse uniq concat
flatten sort`, `int float string type toJSON fromJSON toBase64
fromBase64 toPairs fromPairs`, `bitand bitor bitxor bitnand bitnot
bitshl bitshr bitushr`, plus minimal `now duration date timezone`.
Three expr operators work too: `??` (nil coalescing), `..` (range:
`1..3 == [1,2,3]`), and `matches`. Constant subtrees are folded at
compile time (expr-style `fold`).

Examples:

```text
$ moon run cmd/main -- "median([1, 9, 5])"
5

$ moon run cmd/main -- "fromBase64(toBase64("héllo ✓"))"
"héllo ✓"

$ moon run cmd/main -- "missing ?? 'fallback'"
"fallback"

$ moon run cmd/main -- "sort([3,1,2]) | first"
1
```

## Roadmap — aligning with expr-lang

The reference material below is the target blueprint, staged in
[docs/expr-gap-analysis.md](docs/expr-gap-analysis.md) (stage 4,
estimated 75–105 person-days; stages 4.1 done — resource budgets).

Remaining roadmap items (see
[docs/coverage-vs-expr.md](docs/coverage-vs-expr.md) for the full
matrix):

- **Language front-end (4.4 remainder)**: `{expr}` brace-wrapped
  predicate blocks, `if/else` blocks, `let` declarations + sequences,
  slices `[:]`, optional chaining `?.`, chained comparisons, `not in`,
  right-assoc `**`, hex/oct/binary/exponent literals, raw strings and
  byte strings, comments, `$env`, int/float type system + static type
  checker with `行:列` error locations.
- **Dependencies (4.5)**: full RE2-style regex for `matches` (the
  MoonBit core regex is literal-only), full time objects/timezones.
- **Vm v2 remainder**: `let` variable slots, slice/optional-chain
  instructions, disassembler output.
- **Strings**: `trim`, `upper/lower`, `split`, `replace`, `repeat`,
  `indexOf`, `hasPrefix/hasSuffix`, and regex matching `matches`.
- **Date & time**: `now()`, `duration()`, `date()` (multiple layouts,
  timezones), `timezone()`, date arithmetic and comparison.
- **Numbers**: `max/min/abs`, `ceil/floor/round`, array statistics
  `sum/mean/median`.
- **Arrays & collections**: predicates `all/any/one/none`,
  `map/filter`, `find/findIndex/...`, `groupBy`, `count`, `concat`,
  `flatten`, `uniq`, `join`, `reduce`, `sort/sortBy`, `reverse`,
  `first/last/take`. — DELIVERED 4.4.2 (57/64 builtins total).
- **Maps**: `keys`, `values`, `toPairs/fromPairs`.
- **Type & encoding**: `type()`, `int/float/string` conversions,
  `toJSON/fromJSON`, `toBase64/fromBase64`.
- **Bitwise**: `bitand/bitor/bitxor/bitnand/bitnot/bitshl/bitshr/
  bitushr`.
- **Variables & scope**: `let` declarations, `$env`, predicate
  expressions with `#` / `#acc` / `#index`.

Stages 4.2+ will deliver the pure-computation builtins, a bytecode VM
with an optimizer, and — after a review gate — the expr-language
front-end (lexer/parser/AST/type checker). Items that cannot map 1:1
to MoonBit (Go-reflection struct environments, the Go `time`/`regexp`
dependencies) are tracked as explicit cut items in the gap document.

## Performance & stability report (Walk vs Vm)

Full three-target report in [docs/perf-report.md](docs/perf-report.md).
Both engines share one semantic layer (instructions only dispatch), so
results and error messages are identical by construction and by test.
> ⚠️ The Vm columns of earlier reports (2026-09-06, incl. the tables in
> docs/perf-report.md) are invalid: the end-to-end `Expression::eval`
> never dispatched to the Vm engine until f37f10d, so those "Vm"
> measurements were the tree-walk engine. The tables below and
> docs/coverage-vs-expr.md §7 are the first genuine dual-engine data.

Latest paired benchmarks, same batch (wasm-gc / moonrun; native in
parentheses), 10×N runs, mean:

| Scenario | Walk | Vm |
|---|---|---|
| Precompiled eval (constant-folded) | 13.2 ns (22.9) | 23.2 ns (50.0) |
| Ternary + logic + `??` chain | 107 ns (112) | 76.1 ns (85.8) |
| 50-term un-foldable chain | 1.60 µs (1.35) | 846 ns (615) |
| End-to-end compile + eval | 6.33 µs (13.8) | 6.37 µs (14.4) |
| 100-item relative filter | 4.48 µs (5.50) | 3.72 µs (3.10) |
| 100-item long-predicate filter | 16.3 µs (24.6) | 10.0 µs (7.60) |
| Aggregate `map` over 100 items | 3.57 µs (4.31) | 3.33 µs (3.03) |
| Aggregate `filter`+`sum` over 100 items | 6.09 µs (7.02) | 4.76 µs (4.17) |
| String builtin chain | 527 ns (520) | 472 ns (540) |
| `toJSON`/`fromJSON` roundtrip | 639 ns (839) | 619 ns (932) |
| Tokenize only (engine-independent) | 3.10 µs (5.88) | — |

Reading the numbers: on **iteration-shaped loads** (filters, aggregate
loops, long chains) the Vm leads on every target — the native-backend
gap is the widest (long-predicate filter −69%, aggregates −30% to
−41%, 50-term chain −55%), because the Vm's native relative-filter
loop and typed-slot aggregate loop (one reused sub-VM per aggregate)
remove the per-element allocation tree-walks pay; js (V8 JIT) narrows
the gap by JIT-compiling the recursive walk. On **micro loads**
(folded-constant eval, JSON round-trips) the Vm trails by a fixed
per-eval setup cost. Choose by workload profile — full data and
analysis: [docs/coverage-vs-expr.md](docs/coverage-vs-expr.md) §7.

Stability invariants are asserted **per engine** with one shared
suite (`engine_test/stability_test.mbt`): instance isolation, 500×
deterministic re-evaluation, budget non-bypass against 100k-element
contexts, recovery after parse/transform/budget failures, interleaved
multi-instance evaluation, nesting/wide-structure limits, and
1000-record JSON contexts — all green on both engines. Three
independent safety nets guard behavior: 168 unit/parity tests (green
on native, wasm-gc and js), the internal Walk-vs-Vm parity corpus (207
expressions, results and error messages byte-equal — genuinely green
since f37f10d restored the Vm dispatch), and the external
Jexl differential harness (3,360+ expressions, byte-identical).

## Development

```text
moon test                       # 168 unit/parity tests (add --target native|js)
moon run cmd/main -- "2+2"      # expression runner
./tools/run_diff.sh tools/corpus.txt      # differential check vs Jexl
./tools/run_diff.sh tools/corpus_ctx.txt  # JSON-context corpus
```

See also: [docs/parity-contract.md](docs/parity-contract.md) (JS
semantics and known divergences) and
[docs/expr-gap-analysis.md](docs/expr-gap-analysis.md).
