// SPDX-License-Identifier: Apache-2.0
// mbel engine package — expr-dialect API surface (stage 4.4).
//
// Interface-first per the stage-4.4 review: the new expr front-end
// (parse + lower) delegates to the existing dual-engine core for
// evaluation. When the checker and dedicated expr evaluation land,
// these entry points keep their signatures.

///|
/// Evaluates an expr-dialect source string: new front-end
/// (lexer/parser/lower) feeding the dual-engine core. The instance's
/// max_nodes budget applies at parse time (token ceiling), mirroring
/// the legacy parser path.
pub fn Engine::eval_expr(
  self : Engine,
  source : String,
  ctx : @ast.Value,
) -> @ast.Value raise EngineError {
  let node = @expr.compile_expr_limited(source, self.max_nodes) catch {
    @evaluator.EvalErr(msg) => raise EngineError::EngineErr(msg)
  }
  match node {
    Some(n) => self.eval_ast(n, ctx)
    None => raise EngineError::EngineErr("Cannot evaluate an empty expression")
  }
}

///|
/// Evaluates an already-lowered AST on this instance's configured
/// engine, applying constant folding and the instance budgets. The
/// Vm mode compiles per call here; program caching rides on
/// Expression once expr sources flow through it.
pub fn Engine::eval_ast(
  self : Engine,
  node : @ast.AstNode,
  ctx : @ast.Value,
) -> @ast.Value raise EngineError {
  let folded = @evaluator.constant_fold(node)
  let ev = @evaluator.new_evaluator_limited(
    self.grammar,
    ctx,
    self.max_depth,
    self.max_steps,
  )
  let result = try {
    match self.engine {
      Walk => ev.eval(folded)
      Vm => {
        let prog = @evaluator.compile_program(folded, self.grammar)
        @evaluator.run_program(
          prog,
          self.grammar,
          ctx,
          self.max_depth,
          self.max_steps,
        )
      }
    }
  } catch {
    @evaluator.EvalErr(msg) => raise EngineError::EngineErr(msg)
  }
  result
}

///|
/// Strict (Compile-mode) evaluation: parses, TYPE-CHECKS (stage 4.4.4
/// phase-1 checker), and lowers before delegating to the configured
/// engine — the expr-lang `Compile`-analogue of eval_expr, which stays
/// Eval-mode. Type violations raise expr's compile-mode messages
/// ("invalid operation: + (mismatched types int and string)").
pub fn Engine::eval_expr_checked(
  self : Engine,
  source : String,
  ctx : @ast.Value,
) -> @ast.Value raise EngineError {
  let node = @expr.compile_expr_checked_limited(source, self.max_nodes) catch {
    @evaluator.EvalErr(msg) => raise EngineError::EngineErr(msg)
  }
  match node {
    Some(n) => {
      // Compile-mode env check: identifiers must resolve (ctx keys,
      // registered pools, or let bindings) — expr "unknown name".
      strict_names(n, ctx, self.grammar, [])
      self.eval_ast(n, ctx)
    }
    None => raise EngineError::EngineErr("Cannot evaluate an empty expression")
  }
}

///|
/// expr's compile-mode "unknown name" check for data environments:
/// every top-level identifier must resolve to a context key, a
/// registered function/transform/aggregate, or a lexical let binding.
/// Member names (drill-downs) and relative identifiers are exempt.
fn strict_names(
  node : @ast.AstNode,
  ctx : @ast.Value,
  g : @evaluator.Grammar,
  scope : Array[String],
) -> Unit raise EngineError {
  // let bindings: validate the value, then the name is in scope
  if node.node_type is @ast.VariableDeclaratorNode {
    if node.args.length() > 0 {
      strict_names(node.args[0], ctx, g, scope)
    }
    return
  }
  // sequences thread the scope through their items
  if node.node_type is @ast.SequenceNode {
    let s2 = scope.copy()
    for item in node.args {
      if item.node_type is @ast.VariableDeclaratorNode {
        if item.args.length() > 0 {
          strict_names(item.args[0], ctx, g, s2)
        }
        s2.push(item.ident_name)
      } else {
        strict_names(item, ctx, g, s2)
      }
    }
    return
  }
  if node.node_type is @ast.IdentifierNode {
    if node.from is None && !node.relative && node.ident_name != "$env" {
      let name = node.ident_name
      if !in_array(scope, name) && !ctx_has_key(ctx, name) && !pool_has(g, name) {
        raise EngineError::EngineErr("unknown name " + name)
      }
    }
    return
  }
  walk_children(node, ctx, g, scope)
}

///|
fn walk_children(
  node : @ast.AstNode,
  ctx : @ast.Value,
  g : @evaluator.Grammar,
  scope : Array[String],
) -> Unit raise EngineError {
  match node.left {
    Some(l) => strict_names(l, ctx, g, scope)
    None => ()
  }
  match node.right {
    Some(r) => strict_names(r, ctx, g, scope)
    None => ()
  }
  match node.cond_test {
    Some(t) => strict_names(t, ctx, g, scope)
    None => ()
  }
  match node.consequent {
    Some(c) => strict_names(c, ctx, g, scope)
    None => ()
  }
  match node.alternate {
    Some(a) => strict_names(a, ctx, g, scope)
    None => ()
  }
  match node.subject {
    Some(x) => strict_names(x, ctx, g, scope)
    None => ()
  }
  match node.filter_expr {
    Some(x) => strict_names(x, ctx, g, scope)
    None => ()
  }
  match node.from {
    Some(x) => strict_names(x, ctx, g, scope)
    None => ()
  }
  match node.slice_from {
    Some(x) => strict_names(x, ctx, g, scope)
    None => ()
  }
  match node.slice_to {
    Some(x) => strict_names(x, ctx, g, scope)
    None => ()
  }
  for x in node.array_value {
    strict_names(x, ctx, g, scope)
  }
  for kv in node.obj_value {
    let (_, v) = kv
    strict_names(v, ctx, g, scope)
  }
  for x in node.args {
    strict_names(x, ctx, g, scope)
  }
}

///|
fn in_array(xs : Array[String], x : String) -> Bool {
  for v in xs {
    if v == x {
      return true
    }
  }
  false
}

///|
fn ctx_has_key(ctx : @ast.Value, name : String) -> Bool {
  match ctx {
    @ast.ObjectVal(pairs) => {
      for kv in pairs {
        let (k, _) = kv
        if k == name {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn pool_has(g : @evaluator.Grammar, name : String) -> Bool {
  for entry in g.functions {
    let (n, _) = entry
    if n == name {
      return true
    }
  }
  for entry in g.transforms {
    let (n, _) = entry
    if n == name {
      return true
    }
  }
  @grammar.is_aggregate(name)
}
