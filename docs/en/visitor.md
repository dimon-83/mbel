# Visitor

page.

expr exposes `ast.Walk(node, visitor)` — a single `Visit(*ast.Node)` callback
invoked for every node of a parsed AST, typically used for analysis
(collecting identifiers, static checks) before or after compilation.

**mbel status: no visitor API.** The AST is not exposed through a
walking/visitor utility, and there is no `program.Node()` equivalent on
compiled programs. What exists instead:

- `@expr.dump(@expr.parse(src))` — renders an expr AST as a compact
  s-expression string (`bin(+,int:1,int:2)`, `call(id:filter,id:xs,
  pred(...))`), used across the test suites to assert structure. See
  `expr_test/parser_test.mbt` for many examples.
- `@evaluator.constant_fold(ast)` — the one built-in AST transform
  (compile-time literal folding), operating on the *lowered* AST.
- `@evaluator.disassemble(program)` — renders compiled bytecode; for
  inspecting what the Vm engine will execute (see [Patch](patch.md)).
- Structural equality helpers `@ast.ast_equal` / `@ast.value_equal` for
  writing assertions about trees.

## Writing your own walker

Because the expr AST is a plain recursive enum (`@expr.ENode`, all variants
public), a visitor is a few lines of pattern matching. Example: collect
every identifier used in an expression:

```moonbit
fn collect_idents(n : @expr.ENode) -> Array[String] {
  let out : Array[String] = []
  fn go(node : @expr.ENode) -> Unit {
    match node {
      @expr.EIdent(name) => out.push(name)
      @expr.EMember(b, _, _) => go(b)
      @expr.EIndex(b, i) => {
        go(b)
        go(i)
      }
      @expr.EBinary(_, l, r) => {
        go(l)
        go(r)
      }
      @expr.EUnary(_, x) => go(x)
      @expr.ECond(t, c, a) => {
        go(t)
        match c {
          Some(x) => go(x)
          None => ()
        }
        match a {
          Some(x) => go(x)
          None => ()
        }
      }
      @expr.ELet(_, v, rest) => {
        go(v)
        go(rest)
      }
      @expr.ESeq(items) => {
        for x in items {
          go(x)
        }
      }
      @expr.EArray(xs) => {
        for x in xs {
          go(x)
        }
      }
      @expr.ECall(callee, args) => {
        go(callee)
        for a in args {
          go(a)
        }
      }
      @expr.EPred(inner) => go(inner)
      _ => () // literals, pointers, ... (leaves)
    }
  }
  go(n)
  out
}
```

The node set mirrors expr's own: literals (`ENil`, `EBool`, `EInt`,
`EFloat`, `EStr`, `EBytes`), `EIdent`, `EMember`, `EIndex`, `ESlice`,
`ECall`, `EPred`, `EArray`, `EMap`, `EUnary`, `EBinary`, `ECond` (ternary,
elvis and if/else), `ELet`, `ESeq`, `EPointer`.

To run your analysis in the pipeline, parse with
`@expr.parse_limited(src, max_tokens)` (the token budget guards resources),
then walk the resulting `ENode` before lowering with `@expr.lower`.

## Caveat: lowered AST vs expr AST

The standard-dialect front end *lowers* `ENode` into the legacy AST (`@ast.AstNode`)
that the engines execute. Walking the lowered tree is possible but its node
types differ (`@ast.BinaryExpressionNode`, `@ast.FilterExpressionNode`,
`@ast.FunctionCallNode`, plus the expr additions `SequenceNode`,
`VariableDeclaratorNode`, `SliceNode`). If your analysis targets source
syntax, walk `ENode`; if it targets execution shape, walk the lowered tree
or the disassembly.

A general-purpose visitor/walker API (mirroring `ast.Walk`) is a possible
future addition; the material above covers today's needs without new API.
