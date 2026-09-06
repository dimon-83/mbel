# Getting started

This is the mbel counterpart of
[expr-lang's Getting Started](https://expr-lang.org/docs/getting-started).
mbel evaluates expressions written in the expr dialect (plus a legacy Jexl
dialect) in MoonBit, with two interchangeable engines and strict resource
budgets. Evaluation is fully synchronous: `eval` and `evalSync` are the same
operation (a deliberate, documented divergence from Jexl's Promise API).

## Installation

Add the published module to your MoonBit project:

```text
moon add dimon-83/mbel@0.2.0
```

Import the packages you need:

```moonbit
import {
  "dimon-83/mbel/ast",
  "dimon-83/mbel/engine",
  "dimon-83/mbel/evaluator",
}
```

## Quick start: CLI

The repository ships an expression runner. The expression is argv[1], an
optional JSON context is argv[2], and an optional `vm` engine selector is
argv[3]:

```text
$ moon run cmd/main -- "1 + 2 * 3"
7

$ moon run cmd/main -- "6+x*2>10 ? 'big' : 'small'" '{"x": 3}'
"big"

$ moon run cmd/main -- "age * (3 - 1)" '{"age": 36}'
72

$ moon run cmd/main -- "map(nums, # * 2)" '{"nums": [1, 2, 3, 4, 5]}'
[2,4,6,8,10]

$ moon run cmd/main -- "sum(1..100)"
5050

$ moon run cmd/main -- "reduce(nums, #acc + #, 100)" '{"nums": [1, 2, 3, 4, 5]}'
115
```

The CLI parses the legacy Jexl dialect by default; the demo transforms
`dbl`, `first` and `concatWith` are registered, so pipes work:

```text
$ moon run cmd/main -- "5|dbl|dbl"
20
```

## Quick start: library

Create an engine instance, build a context value, and evaluate:

```moonbit
let inst = @engine.new()

// A context is plain data: an object of name -> Value pairs. JSON,
// maps, arrays, strings, numbers, booleans and nil all map directly.
let ctx = @ast.ObjectVal([
  ("user", @ast.ObjectVal([("age", @ast.NumVal(36.0))])),
])

let v = try {
  @engine.Engine::eval_expr(
    inst,
    "user.age > 18 ? 'adult' : 'minor'",
    ctx,
  )
} catch {
  @engine.EngineErr(msg) => abort(msg)
}
// @ast.StrVal("adult")
```

Three evaluation entries exist (see [Environment](environment.md)):

| Entry | Dialect / mode | Behavior |
|---|---|---|
| `Engine::eval` | legacy Jexl | JS dynamic semantics, locked by the Jexl corpus |
| `Engine::eval_expr` | expr, **Eval mode** | typed runtime semantics, no static checks |
| `Engine::eval_expr_checked` | expr, **Compile mode** | runs the static checker first (type errors, unknown names) |

Every entry runs on either engine — `Walk` (reference tree-walk, default)
or `Vm` (bytecode) — with identical results and error messages, and honors
the instance budgets (see [Environment](environment.md) → Budgets):

```moonbit
@engine.Engine::set_engine(inst, Vm)
@engine.Engine::set_limits(inst, 10000, 10000, 1000000) // nodes, depth, steps
```

## Compile once, evaluate many

As in expr, compilation is separable from evaluation:

```moonbit
let e = @engine.Engine::compile(inst, "user.age * 2") catch {
  @engine.EngineErr(msg) => abort(msg)
}
let r = @engine.Expression::eval(e, ctx) catch {
  @engine.EngineErr(msg) => abort(msg)
}
```

`Expression` caches the parsed AST (and, in Vm mode, the compiled bytecode)
across evaluations. Evaluation is atomic per call and per instance: an
engine instance is not safe for concurrent mutation, but distinct instances
are fully isolated — see the stability contract in the repository tests.

## Next steps

- [Environment & configuration](environment.md) — contexts, `$env`, budgets.
- [Custom functions](functions.md) — registering functions, transforms, operators.
- [Language definition](language-definition.md) — the expr dialect in mbel.
