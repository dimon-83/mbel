// SPDX-License-Identifier: Apache-2.0
// mbel engine package — expr-dialect API surface (stage 4.4).
//
// Interface-first per the stage-4.4 review: the new expr front-end
// (parse + lower) delegates to the existing dual-engine core for
// evaluation. When the checker and dedicated expr evaluation land,
// these entry points keep their signatures.

///|
/// Evaluates an expr-dialect source string: new front-end
/// (lexer/parser/lower) feeding the dual-engine core.
pub fn Engine::eval_expr(
  self : Engine,
  source : String,
  ctx : @ast.Value,
) -> @ast.Value raise EngineError {
  let node = @expr.compile_expr(source) catch {
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
