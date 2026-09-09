# Custom functions

page.

In the reference language, custom functions come from the environment (struct methods or map
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
in both dialects (classic-dialect pipes and standard-dialect pipes desugar into a call with
the left side as the first argument):

```moonbit
@engine.Engine::add_transform(inst, "dbl", fn(args) {
  @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
})
@engine.Engine::eval_expr(inst, "5|dbl|dbl", @ast.ObjectVal([])) // NumVal(20.0)
```

Batch registration: `add_functions([...])`, `add_transforms([...])`; lookup:
`get_function(name) -> Fn?`, `get_transform(name) -> Fn?`.

## Expression-defined functions (JSON file)

Closure registration requires writing MoonBit. **Expression-defined
functions** open the same capability to data: the function body is an
expression source string, loaded from a structured (JSON) definition.

```moonbit nocheck
// params omitted: free identifiers are auto-extracted from the body
let resolved = @engine.Engine::add_expression_functions(
  inst,
  [{ name: "tax", params: None, body: "price * rate" }],
  None,
)
// resolved == [("tax", ["price", "rate"])]

@engine.Engine::eval_expr(inst, "tax(100, 0.13)", @ast.ObjectVal([]))
@engine.Engine::eval_expr(inst, "100 | tax()", @ast.ObjectVal([])) // standard pipe
@engine.Engine::eval(inst, "100|tax", @ast.ObjectVal([]))          // classic pipe
```

- **Both pools**: `f(x)`, standard pipes `x | f()`, and classic pipes
  `x | f` all resolve.
- **Auto-extracted params** (the standalone helper
  `user_function_params(name, body)` is also available): the body is
  compiled with the standard-dialect front end and constant-folded,
  then free identifiers are collected — let-bound names, call callees,
  member drill-down roots (`a` in `a.b`), relative predicate
  identifiers (`.price`) and `$env` are excluded — in first-appearance
  order, deduplicated.
- **env-default fallback**: the third argument `defaults` takes an
  object (typically the evaluation env); the body context is the
  defaults pairs overridden by the positional arguments' parameter
  names — under env `{price: 200, rate: 0.5}`, `tax()` yields `100`
  and `tax(80)` yields `40`. Pass `None` for purely lexical parameters
  (unpassed parameters evaluate as undefined).
- **Atomic validation**: names must be valid identifiers (no keywords,
  no `$env`), must not collide with the 15 aggregates (aggregate
  dispatch intercepts before the pool lookup — such a registration
  could never be called), and duplicate names are rejected; body
  compile errors carry a `function "name":` prefix. Any failure
  registers nothing. Ordinary builtin names may be overridden (upsert,
  like `add_function`).
- **Evaluation semantics**: bodies run on the registering instance's
  current engine (Walk/Vm; the Vm caches one program per function);
  errors carry a `function "name":` prefix. Depth/step budgets restart
  per call (like native registered callbacks), so recursion is bounded
  only by the host stack — make sure your functions terminate.

### Functions file format v1 (playground)

The playground's "🧩 Custom functions" card loads UTF-8 JSON (see
`playground/functions.example.json`):

```json
{
  "version": 1,
  "functions": [
    { "name": "double", "params": ["x"], "body": "x * 2", "description": "Doubles" },
    { "name": "tax", "body": "price * rate", "description": "params omitted, auto-extracted" }
  ],
  "env": { "price": 200, "rate": 0.5 }
}
```

| Field | Rule |
| --- | --- |
| `version` | required, only `1` accepted |
| `functions` | required array (may be empty) |
| `functions[].name` | required, valid identifier, not a keyword / aggregate / `$env`, unique in the file |
| `functions[].params` | optional (auto-extracted); array of strings, each a valid non-keyword identifier, unique |
| `functions[].body` | required, standard-dialect expression |
| `functions[].description` | optional, shown in the card tooltip |
| `env` | optional object, **page-level example environment**: the page fills the env box on load; the engine ignores it |

Unknown fields are rejected (typo protection); validation is atomic and
errors carry the `functions[i]` index.

**Persistence semantics**: the wasm is stateless — every export call
builds a fresh engine, and restarting the host does **not** reload
custom functions. The playground stores the file in localStorage and
restores it on page load; applications embedding mbel.wasm must persist
the JSON themselves and pass it on every
`eval_with_functions(code, env, funcs_json, mode, engine)` call
(`mode` ∈ `eval`/`checked`/`legacy`). Hosts using the MoonBit API
directly are unaffected: a long-lived Engine instance keeps its
registrations.

## Custom operators

The classic-dialect grammar is extensible per instance:

- `add_binary_op(operator, precedence, f)` — eager operands (both sides are
  values).
- `add_binary_op_manual(operator, precedence, f)` — lazy operands
  (`(Lazy, Lazy) -> Value`); used for short-circuiting operators.
- `add_unary_op(operator, f)` — unary operator (precedence fixed very high).
- `remove_op(operator)` — remove an element/operator from this instance.

The standard dialect's operator set is fixed (see
[Language definition](language-definition.md) → Operators); custom
operators are a legacy-dialect facility.

## Builtins

The instance is seeded with the builtin library (56 functions) plus 15
predicate aggregates; see the README's builtins section and
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

- A function name in the functions pool is callable in both the standard
  end and the legacy dialect.
- Aggregate names are intercepted before pool lookup — do not shadow them
  with `add_function` (registering e.g. `"map"` will not affect aggregate
  dispatch).
- Callbacks run synchronously inside an evaluation; they must terminate
  (budgets charge allocation, not your callback's CPU time) and must not
  re-enter the same instance concurrently (use separate instances for
  parallelism).
