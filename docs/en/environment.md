# Environment and configuration

Counterpart of expr-lang's
[Environment](https://expr-lang.org/docs/environment) and
[Configuration](https://expr-lang.org/docs/configuration) pages.

In expr the "environment" is typed (a Go struct or a map) and configuration
is a set of compile options. mbel has **one data environment** — a plain
`@ast.Value`, typically an object — and configuration lives on the engine
instance. The mapping table at the end lists expr's options and their mbel
status.

## The environment is data

Every evaluation receives a context value. There is no struct environment
and no reflection: member access, indexing and iteration work on data
objects and arrays only (Go reflection is a documented cut — env values
cannot carry methods, so method calls are not supported on data values).

Build a context from MoonBit values:

```moonbit
let ctx = @ast.ObjectVal([
  ("name", @ast.StrVal("Archer")),
  ("age", @ast.NumVal(36.0)),
  ("tags", @ast.ArrayVal([@ast.StrVal("agent"), @ast.StrVal("spy")])),
  ("nil_v", @ast.NullVal),
])
```

or from JSON text (CLI contexts, or `@builtin.json_to_value`):

```moonbit
let j = @json.parse("{\"user\": {\"age\": 36}}") catch { _ => abort("bad json") }
let ctx = @builtin.json_to_value(j) // ObjectVal[("user", ObjectVal[("age", NumVal 36.0)])]
```

JSON mapping: `null` → `NullVal`, numbers → floating-point `NumVal`,
strings/booleans/arrays/objects map 1:1. JSON numbers are doubles, so
context integers beyond 2^53 lose precision; exact integers come from
integer literals and integer arithmetic (see
[Language definition](language-definition.md) → Types).

Inside an expression:

```text
name          # context key lookup            -> "Archer"
user.age      # member access                 -> 36
tags[0]       # array index                   -> "agent"
user["age"]   # index with a string           -> 36
'agent' in tags                               -> true
$env          # the whole context as a value
len($env)     # number of context keys
```

`$env` evaluates to the root context (user variables only — builtins are
not part of it). `let` bindings shadow context keys inside their scope.

## Missing keys: Eval mode vs Compile mode

- `Engine::eval_expr` (Eval mode, expr's `expr.Eval`): a missing key
  evaluates to nil/undefined — dynamic, no error:
  `missing ?? "fallback"` → `"fallback"`.
- `Engine::eval_expr_checked` (Compile mode, expr's `expr.Compile`): the
  checker validates that every top-level identifier resolves to a context
  key, a registered function/transform/aggregate, or a `let` binding;
  anything else raises `unknown name <name>` (expr's wording). Add explicit
  keys (possibly nil) for names that may be absent.
- `Engine::eval` (legacy Jexl dialect): JS semantics — missing keys are
  undefined, comparisons and drills behave like JavaScript.

## Per-instance state and isolation

Each `Engine` owns its grammar: an operator/function/transform registry plus
caches. Mutations affect only that instance:

```moonbit
let a = @engine.new()
let b = @engine.new()
@engine.Engine::add_transform(a, "shout", fn(args) { ... })
@engine.Engine::remove_op(a, "+")

@engine.Engine::eval(a, "\"hey\"|shout", ctx) // works
@engine.Engine::eval(b, "1+2", ctx)           // works (b untouched)
```

Evaluation is atomic per instance — no yield points exist inside an
evaluation — so the concurrency model is: **parallelism happens across
instances** (e.g. one instance per worker), never by sharing one instance.
Registered callbacks execute synchronously; they must not block on async
I/O from within an evaluation.

## Budgets (resource limits)

Every instance carries three budgets, set with
`Engine::set_limits(max_nodes, max_depth, max_steps)`; `0` disables a limit.
Defaults: nodes 10000, depth 10000, steps 1000000.

| Budget | Where enforced | On failure |
|---|---|---|
| `max_nodes` | parse time: expression node/token ceiling (legacy and expr front end; expr front end counts AST nodes, plus a recursion/nesting guard) | `expression is too large (more than N nodes)` / `expression is too deeply nested` |
| `max_depth` | evaluation, **on both engines** (tree-walk recursion; bytecode carries per-instruction source-AST depths) | `expression is too deep (more than N levels)` |
| `max_steps` | evaluation at allocation points (arrays, objects, ranges, slices, filters) | `memory budget exceeded` |

Ranges are additionally hard-capped at 1e6 elements. Parse budgets protect
MoonBit's fixed wasm stack: deep nesting (parens/unary chains), oversized
programs and integer literals beyond int64 are rejected at parse time.

## Configuration options: expr vs mbel

expr option | mbel status
---|---
`expr.Env(env)` typed struct/map env | No struct env. Context is always data (`@ast.Value`); see [Environment](#the-environment-is-data)
`expr.AllowUndefinedVariables` | Default Eval-mode behavior; the strict entry (`eval_expr_checked`) validates names against the context — add nil keys to allow a name
`expr.AsBool/AsInt/AsFloat64/AsAny/AsKind` return-type assertions | No compile-time return-type assertion. Result types are the engine's typed values (`@ast.Value`); use `type()` or kind matching in code
`expr.WithContext("ctx")` | Not available (no user-function context injection)
`expr.ConstExpr("fib")` compile-time evaluation | Partial: the engine constant-folds pure literal subtrees automatically (`evaluator.constant_fold`); no opt-in per-function marking
`expr.Patch(...)` AST patching | Not available — see [Patch](patch.md)
`expr.Timezone(...)` / timezone objects | Minimal: `now()`, `duration()`, `date()` (ISO), `timezone()` = UTC. No time.Time objects or tzdata (documented cut)
`expr.Optimize` (12 passes) | Constant folding only; further optimizer passes are roadmap items
`expr.MaxNodes` | `set_limits(max_nodes, ...)` (default 10000)
Memory budget (1e6 units) | `set_limits(..., max_steps)` charged at allocation points

Each divergence above is documented with its rationale in
docs/expr-gap-analysis.md.
