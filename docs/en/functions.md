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
  per call (like native registered callbacks); recursion is capped by
  an **instance-wide 256-level counter** (mutual and cross-batch
  recursion included), raising
  `function call depth exceeded (more than 256 levels)` — see the
  Security model below.

### Functions file format v1 (playground)

The playground's "🧩 Custom functions" drawer (opened from the control
row) loads UTF-8 JSON (see `playground/functions.example.json`):

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

## Security model

The engine confines both "code" and "data" to a **pure-evaluation
sandbox**: it depends only on core, with no FFI/host access, no
eval-of-eval, no reflection; classic-dialect calls are pool lookups of
registered closures. Expressions therefore cannot reach the host
system — the danger is not code escape but **resource exhaustion
(DoS)**, defended in two layers:

1. **A functions file is code — load it only from trusted sources.**
   Custom-function bodies are expression source, constrained by the
   same parser and budgets as direct evaluation; names/params are pool
   lookup keys and are never re-parsed. In the playground, a loaded
   .json has the same power as your expression.
2. **Resource budgets are enforced inside the engine** (0 disables):

| Guard | Cap | When |
| --- | --- | --- |
| parse node budget (both dialects) | max_nodes = 10000 | at parse |
| parse frames / AST depth | 1000 / 1000 | expr parse |
| **source-length cap** | max_nodes × 16 chars | before tokenizing (a single huge string literal is one token) |
| eval depth / steps | 10000 / 1000000 (charged at allocations) | at eval (both engines) |
| range literal `..` | ≤ 1e6 elements (Int64 span, no 32-bit wrap) | before materializing |
| repeat output | ≤ 1e6 chars (amplification: `repeat(long, 1e6)` rejected) | before building |
| **user-function recursion depth** | 256 levels (instance-wide counter; mutual and cross-batch recursion included) | per call |
| deep-nested values (== / toJSON / to_string / flatten) | 1024 levels | before comparison/serialization |

Exceeding any cap raises a clean evaluation error (e.g. `function call
depth exceeded (more than 256 levels)`, `value nesting too deep (more
than 1024 levels)`) instead of crashing the host. Hosts evaluating
third-party expressions keep these budgets on by default.

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
- Time (4): now duration date timezone

`now()`, `date()` and `duration()` all evaluate to **int64 nanoseconds**
(`now()`/`date()`: nanoseconds since the Unix epoch; `duration()`: a
nanosecond count — the same unit as Go's `UnixNano` and `Duration`).
One unit throughout is what makes `date("2024-01-01") + duration("24h")`
exact int64 addition.

`date()` follows expr: it takes Go reference layouts, not a strftime
pattern. With no layout it scans expr's seven defaults (`2006-01-02`,
`15:04:05`, `2006-01-02 15:04:05`, RFC3339, RFC822, RFC850, RFC1123); a
caller may pass its own layout. A numeric offset carried by the string is
applied, which is where expr supports fixed offsets:

```text
date("2024-01-01T00:00:00+08:00")      // 1704038400000000000
date("2024-01-01T00:00:00.5+08:00")    // 1704038400500000000
date("01 Jan 24 15:04 UTC")            // 1704121440000000000   (RFC822)
date("01/02/2024", "02/01/2006")       // 1706745600000000000   (day/month/year)
```

expr's call forms are accepted: a location may come first
(`date(timezone("UTC"), "2024-01-01")`) or last, and `now(tz)` is the same
instant in a location (a nanosecond count is location-free). Two cuts
remain, and both fail the same way Go does rather than differing
silently: an IANA zone name needs the zone database, and `Local` needs
host FFI. `timezone("+08:00")` is an error in Go too
(`time.LoadLocation` rejects it), so offsets belong in the date string.
Relative to Go's `time.Parse`, a time-only layout is rejected instead of
reproducing its int64 overflow.
- Predicate aggregates (15): all none any one filter map count sum find
  findIndex findLast findLastIndex groupBy sortBy reduce

Several builtins return typed integers per expr semantics: `len`, `count`,
`indexOf`, `lastIndexOf`, `findIndex`, `findLastIndex`, `int()`, and
integer-preserving `abs`/`min`/`max`/`sum` on integer inputs.

**Aggregates are language-level, not user-registrable**: the aggregate set
is fixed by name; the predicate argument is recognized at parse time
(`#`, `#index`, `#acc`). If you need a new aggregate-like function, register
a plain function and pass a pre-computed array, or open an issue.

## Dialect-sensitive builtins

Two builtins answer differently per dialect, because the two value models
differ. Both answers are correct for their model, and both are locked by
tests:

| Expression | Standard dialect (`eval_expr`) | Classic dialect (`eval`) |
|---|---|---|
| `len('👍')` | `1` — expr counts code points | `2` — JS counts UTF-16 code units |
| `len("a👍b")` | `3` | `4` |
| `type(5.0)` | `"float"` (expr's name) | `"number"` (JS's name) |
| `type(5)` | `"int"` | `"number"` |

The standard dialect reaches its column through a lowering step in the
expr front end, so the classic dialect keeps the answers its corpus locks.
`matches` is not dialect-sensitive: an RE2 pattern means the same thing in
both, including Unicode classes (`\p{L}`, `\p{Greek}`, `\p{Any}`,
`\P{…}`) — see [Language definition](language-definition.md).

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
