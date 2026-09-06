# Custom functions

Counterpart of expr-lang's [Functions](https://expr-lang.org/docs/functions)
page.

In expr, custom functions come from the environment (struct methods or map
values) or from `expr.Function(name, fn, ...type hints)`. mbel has no Go
functions and no reflection, so the equivalent is **registration on the
engine instance**: functions, transforms, and operators are MoonBit
closures you register by name. There are no type hints — arguments arrive as
dynamically typed `@ast.Value`s and your callback coerces them.

## Registered functions

`add_function(name, fn)` puts a function in the functions pool (callable
from both dialects):

```moonbit
@engine.Engine::add_function(
  inst,
  "double",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
  },
)

@engine.Engine::eval_expr(inst, "double(21)", @ast.ObjectVal([])) // NumVal(42.0)
```

The callback type is `Fn = (Array[@ast.Value]) -> @ast.Value raise
EvalError`. Raise `@evaluator.EvalErr("...")` to surface an error:

```moonbit
@engine.Engine::add_function(
  inst,
  "positive",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    let x = @evaluator.to_number(args[0])
    if x < 0.0 {
      raise @evaluator.EvalErr("positive: argument must be >= 0")
    }
    @ast.NumVal(x)
  },
)
```

Helpers in the `evaluator` package cover coercion and formatting:
`to_number(v)`, `to_string(v)`, `truthy(v)`, `value_equal(a, b)`, plus the
typed-value kinds (`IntVal` for integers, `NumVal` for floats — see
[Language definition](language-definition.md) → Types). Note the typed
signal: if an argument is (or contains) an `IntVal`, expr typed semantics
apply to operators; your function may return `@ast.IntVal` to stay integer
(returns wrap int64), or `@ast.NumVal` for floats.

## Transforms (pipes)

`add_transform(name, fn)` registers a pipeline function for the `|` syntax
in both dialects (legacy Jexl pipes and expr pipes desugar into a call with
the left side as the first argument):

```moonbit
@engine.Engine::add_transform(inst, "dbl", fn(args) {
  @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
})
@engine.Engine::eval_expr(inst, "5|dbl|dbl", @ast.ObjectVal([])) // NumVal(20.0)
```

Batch registration: `add_functions([...])`, `add_transforms([...])`; lookup:
`get_function(name) -> Fn?`, `get_transform(name) -> Fn?`.

## Custom operators

The legacy Jexl grammar is extensible per instance:

- `add_binary_op(operator, precedence, f)` — eager operands (both sides are
  values).
- `add_binary_op_manual(operator, precedence, f)` — lazy operands
  (`(Lazy, Lazy) -> Value`); used for short-circuiting operators.
- `add_unary_op(operator, f)` — unary operator (precedence fixed very high).
- `remove_op(operator)` — remove an element/operator from this instance.

The expr front end's operator set is fixed (see
[Language definition](language-definition.md) → Operators); custom
operators are a legacy-dialect facility.

## Builtins

The instance is seeded with the builtin library (56 functions) plus 15
predicate aggregates; see the README's "expr-lang builtins" section and
[Language definition](language-definition.md) → Functions for the full
lists.

- Math (8): abs ceil floor round max min mean median
- String (15): trim trimPrefix trimSuffix upper lower split splitAfter
  replace repeat join indexOf lastIndexOf hasPrefix hasSuffix string
- Collection (12): len first last get take keys values reverse uniq concat
  flatten sort
- Conversion (9): int float type toJSON fromJSON toBase64 fromBase64
  toPairs fromPairs
- Bitwise (8): bitand bitor bitxor bitnand bitnot bitshl bitshr bitushr
- Time (4, minimal): now duration date timezone
- Predicate aggregates (15): all none any one filter map count sum find
  findIndex findLast findLastIndex groupBy sortBy reduce

Several builtins return typed integers per expr semantics: `len`, `count`,
`indexOf`, `lastIndexOf`, `findIndex`, `findLastIndex`, `int()`, and
integer-preserving `abs`/`min`/`max`/`sum` on integer inputs.

**Aggregates are language-level, not user-registrable**: the aggregate set
is fixed by name; the predicate argument is recognized at parse time
(`#`, `#index`, `#acc`). If you need a new aggregate-like function, register
a plain function and pass a pre-computed array, or open an issue.

## Calling convention notes

- A function name in the functions pool is callable in both the expr front
  end and the legacy dialect.
- Aggregate names are intercepted before pool lookup — do not shadow them
  with `add_function` (registering e.g. `"map"` will not affect aggregate
  dispatch).
- Callbacks run synchronously inside an evaluation; they must terminate
  (budgets charge allocation, not your callback's CPU time) and must not
  re-enter the same instance concurrently (use separate instances for
  parallelism).
