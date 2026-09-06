# Patch

Counterpart of expr-lang's [Patch](https://expr-lang.org/docs/patch) page.

expr lets you *modify an expression before compilation*: `ast.Patch(node,
newNode)` replaces a node in place during an `ast.Walk`, wired in through
the `expr.Patch(visitor)` compile option — used to replace variables with
constants, rewrite operators into function calls, or implement operator
overloading (`expr.Operator("+", "add")`).

**mbel status: no patch API.** There is no AST-rewriting visitor hook and no
compile option to install patchers. The optimizer surface today is a single
built-in transform:

- `@evaluator.constant_fold(ast : @ast.AstNode) -> @ast.AstNode` — folds
  pure literal subtrees at compile time (`42 + 1` becomes a single `43`
  constant). It runs automatically before evaluation on every path
  (`Engine::eval`, `eval_expr`, `eval_expr_checked`, `Expression::eval`).

Further optimizer passes (expr's fold/inArray/filterLen/countAny/sumRange
family) and a public rewrite hook are roadmap items.

## What to use instead

**Rewriting at the source level.** Since the expr AST is a plain enum, you
can build a *new* tree (the pattern-matching approach shown on the
[Visitor](visitor.md) page) and hand it to the pipeline:

```moonbit
let parsed = @expr.parse_limited("x + 1", 0)
// ... build `rewritten : @expr.ENode` by pattern matching ...
let lowered = @expr.lower(rewritten) // -> @ast.AstNode
```

**Rewriting at the lowered level.** The legacy AST is mutable and has public
constructors (`@ast.literal`, `@ast.binary_expr`, `@ast.identifier`, ...).
Example — replace an identifier node's subtree with a literal (a toy
stand-in for expr's "replace a variable with a constant"):

```moonbit
// inside some analysis over @ast.AstNode:
match node.node_type {
  @ast.IdentifierNode =>
    if node.ident_name == "PI" && node.from is None {
      node.node_type = @ast.LiteralNode
      node.value = @ast.NumVal(3.14159)
    }
  _ => ()
}
```

Mutating a lowered tree before `Engine::eval_ast` (or before handing it to
the engines) has the same effect as expr's patch phase: the engines never
see the pre-patch shape. Remember that identifiers bound by `let` sequences
and predicate flags (`is_pred`) carry meaning — rewrite with care.

**Inspecting instead of patching.** When the goal is understanding what the
Vm engine will execute, disassemble the compiled program:

```moonbit
let node = @expr.compile_expr("map(nums, # * 2)") // or Engine::compile
let prog = @evaluator.compile_program(
  @evaluator.constant_fold(node.unwrap()),
  @evaluator.default_grammar(),
)
println(@evaluator.disassemble(prog))
// 0  LOADCTX 0  ; "nums"
// 1  CALLAGG 1  ; map argc=1 pred
```

Expected disassembly shapes are asserted in `expr_test/opcode_test.mbt`.

## Operator overloading?

expr's `expr.Operator("+", "add")` redirects an operator to a function.
mbel has no typed operator overloading; in the legacy Jexl dialect you can
redefine an operator *globally per instance* with `add_binary_op` /
`remove_op` (see [Functions](functions.md) → Custom operators). In the expr
front end the operator set and its typed semantics are fixed.
