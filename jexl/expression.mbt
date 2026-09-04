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
  jexl : Jexl
  expr_str : String
  mut compiled : @ast.AstNode?
}

///|
/// Forces compilation of the expression string. Can be called
/// multiple times — useful when the owning instance's grammar
/// changes. Mirrors `Expression.compile`.
pub fn Expression::compile(self : Expression) -> Unit raise JexlError {
  let toks = match @lexer.tokenize_with(self.expr_str, self.jexl.elements) {
    Ok(t) => t
    Err(msg) => raise JexlError::JexlErr(msg)
  }
  let ast = @parser.parse_with_limits(
    toks,
    self.jexl.elements,
    self.jexl.max_nodes,
  ) catch {
    @parser.ParseErr(msg) => raise JexlError::JexlErr(msg)
  }
  self.compiled = ast
}

///|
/// Evaluates the expression within a context, compiling first if
/// needed. Mirrors Jexl's `Expression.eval`/`evalSync` (identical
/// here — synchronous).
pub fn Expression::eval(
  self : Expression,
  ctx : @ast.Value,
) -> @ast.Value raise JexlError {
  if self.compiled is None {
    self.compile()
  }
  let node = match self.compiled {
    Some(n) => n
    None => raise JexlError::JexlErr("Cannot evaluate an empty expression")
  }
  let evaluator = @evaluator.new_evaluator_limited(
    self.jexl.grammar,
    ctx,
    self.jexl.max_depth,
    self.jexl.max_steps,
  )
  let result = evaluator.eval(node) catch {
    @evaluator.EvalErr(msg) => raise JexlError::JexlErr(msg)
  }
  result
}

///|
/// Evaluates with an empty context.
pub fn Expression::eval_default(
  self : Expression,
) -> @ast.Value raise JexlError {
  self.eval(@ast.ObjectVal([]))
}
