// SPDX-License-Identifier: Apache-2.0
// mbel expr package — the expr-dialect entry point: parse + lower +
// evaluate on either engine (delegating to the dual-engine core, per
// the review's "define the new API early, delegate internally").

///|
/// Parses and lowers an expr-dialect source to the legacy AST that
/// the dual-engine core executes.
pub fn compile_expr(
  source : String,
) -> @ast.AstNode? raise @evaluator.EvalError {
  let node = parse(source) catch {
    ParseErrExpr(msg, line, col) =>
      raise @evaluator.EvalErr(
        "parse error at " +
        line.to_string() +
        ":" +
        col.to_string() +
        ": " +
        msg,
      )
  }
  let lowered = lower(node) catch {
    LowerErr(msg) => raise @evaluator.EvalErr(msg)
  }
  Some(lowered)
}
