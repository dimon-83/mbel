# mbel — Expression Engine for MoonBit

mbel is a native MoonBit expression-language engine that started as a
full port of [Jexl](https://github.com/TomFrost/Jexl) and is evolving,
stage by stage, toward the semantic richness of
[expr-lang/expr](https://github.com/expr-lang/expr). The end goal is a
safe, reliable, high-performance expression engine suited to rules
engines, dynamic configuration, low-code platforms, and workflow
orchestration.

Current status: the complete **Jexl language and API surface** is
ported and verified byte-for-byte against the real Jexl runtime, with
resource budgets (expr-style node/depth/step limits) already in place.
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

Contexts are JSON: `null` → `nil`, numbers and nested objects/arrays
work as expected. A few demo transforms (`dbl`, `first`,
`concatWith`) are registered in the CLI, so pipes work too:

```text
$ moon run cmd/main -- "[1,2,3]|first"
1

$ moon run cmd/main -- "5|dbl|dbl"
20
```

## Using mbel as a library

The engine is organized into small packages — `grammar`, `lexer`,
`parser`, `ast`, `evaluator`, and `jexl` (the top-level API):

```moonbit
import {
  "dexter/mbel/ast",
  "dexter/mbel/evaluator",
  "dexter/mbel/jexl",
}

let inst = @jexl.new_jexl()

// Evaluate against a context
let ctx = @ast.ObjectVal([
  ("user", @ast.ObjectVal([("age", @ast.NumVal(36.0))])),
])
let v = try {
  @jexl.Jexl::eval(inst, "user.age > 18 ? 'adult' : 'minor'", ctx)
} catch {
  @jexl.JexlErr(msg) => abort(msg)
} // StrVal("adult")

// Register transforms / functions / operators
@jexl.Jexl::add_transform(
  inst,
  "dbl",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
  },
)
let doubled = try {
  @jexl.Jexl::eval(inst, "21|dbl", @ast.ObjectVal([]))
} catch {
  @jexl.JexlErr(msg) => abort(msg)
} // NumVal(42.0)

// expr-style resource budgets: nodes at parse time, depth + steps at
// eval time (0 disables a limit)
@jexl.Jexl::set_limits(inst, 10000, 10000, 1000000)
```

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

## Roadmap — aligning with expr-lang

The reference material below is the target blueprint, staged in
[docs/expr-gap-analysis.md](docs/expr-gap-analysis.md) (stage 4,
estimated 75–105 person-days; stages 4.1 done — resource budgets).

- **Literals & data**: booleans, integers (decimal, hex `0x`, octal
  `0o`, binary `0b`), floats, strings (incl. backtick raw strings),
  byte arrays `b"..."`, arrays, maps `{key: value}`, `nil`.
- **Operators**: full arithmetic (`+ - * / % ^`/`**`), comparisons,
  logic (`not/! and/&& or/||`), conditionals (ternary, `??`, `if-else`
  blocks), member access with optional chaining `?.`, `in`, ranges
  `..`, slices `[:]`, pipes `|`.
- **Strings**: `trim`, `upper/lower`, `split`, `replace`, `repeat`,
  `indexOf`, `hasPrefix/hasSuffix`, and regex matching `matches`.
- **Date & time**: `now()`, `duration()`, `date()` (multiple layouts,
  timezones), `timezone()`, date arithmetic and comparison.
- **Numbers**: `max/min/abs`, `ceil/floor/round`, array statistics
  `sum/mean/median`.
- **Arrays & collections**: predicates `all/any/one/none`,
  `map/filter`, `find/findIndex/...`, `groupBy`, `count`, `concat`,
  `flatten`, `uniq`, `join`, `reduce`, `sort/sortBy`, `reverse`,
  `first/last/take`.
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

## Development

```text
moon test                       # 111 unit/parity tests
moon run cmd/main -- "2+2"      # expression runner
./tools/run_diff.sh tools/corpus.txt      # differential check vs Jexl
./tools/run_diff.sh tools/corpus_ctx.txt  # JSON-context corpus
```

See also: [docs/parity-contract.md](docs/parity-contract.md) (JS
semantics and known divergences) and
[docs/expr-gap-analysis.md](docs/expr-gap-analysis.md).
