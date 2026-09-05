// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// jexl package: Expression type.
//
// Ported from Jexl's lib/Expression.js. An Expression wraps an
// expression string and lazily compiles (tokenize + parse) it against
// the owning Jexl instance's element registry. The compiled AST is
// cached and reused by later evaluations.

///|
/// A lazily compiled expression string bound to a Jexl instance.
/// Mirrors Jexl's `Expression` class.
pub struct Expression {
  engine : Engine
  expr_str : String
  mut compiled : @ast.AstNode?
  mut program : @evaluator.Program?
}

///|
/// Forces compilation of the expression string. Can be called
/// multiple times — useful when the owning instance's grammar
/// changes. Mirrors `Expression.compile`.
pub fn Expression::compile(self : Expression) -> Unit raise EngineError {
  let toks = match @lexer.tokenize_with(self.expr_str, self.engine.elements) {
    Ok(t) => t
    Err(msg) => raise EngineError::EngineErr(msg)
  }
  let ast = @parser.parse_with_limits(
    toks,
    self.engine.elements,
    self.engine.max_nodes,
  ) catch {
    @parser.ParseErr(msg) => raise EngineError::EngineErr(msg)
  }
  // Constant-folding pass (expr-style fold): pure literal subtrees
  // are computed at compile time.
  self.compiled = match ast {
    Some(node) => Some(@evaluator.constant_fold(node))
    None => None
  }
  // Grammar may have changed: drop any cached bytecode so the next
  // Vm-mode evaluation recompiles against the new element registry.
  self.program = None
}

///|
/// Evaluates the expression within a context, compiling first if
/// needed. Mirrors Jexl's `Expression.eval`/`evalSync` (identical
/// here — synchronous).
pub fn Expression::eval(
  self : Expression,
  ctx : @ast.Value,
) -> @ast.Value raise EngineError {
  if self.compiled is None {
    self.compile()
  }
  let node = match self.compiled {
    Some(n) => n
    None => raise EngineError::EngineErr("Cannot evaluate an empty expression")
  }
  let evaluator = @evaluator.new_evaluator_limited(
    self.engine.grammar,
    ctx,
    self.engine.max_depth,
    self.engine.max_steps,
  )
  let result = evaluator.eval(node) catch {
    @evaluator.EvalErr(msg) => raise EngineError::EngineErr(msg)
  }
  result
}

///|
/// Evaluates with an empty context.
pub fn Expression::eval_default(
  self : Expression,
) -> @ast.Value raise EngineError {
  self.eval(@ast.ObjectVal([]))
}
