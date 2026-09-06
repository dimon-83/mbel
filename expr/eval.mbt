// SPDX-License-Identifier: Apache-2.0
// mbel expr package — the expr-dialect entry point: parse + lower +
// evaluate on either engine (delegating to the dual-engine core, per
// the review's "define the new API early, delegate internally").

///|
/// Parses and lowers an expr-dialect source to the legacy AST that
/// the dual-engine core executes (no token budget).
pub fn compile_expr(
  source : String,
) -> @ast.AstNode? raise @evaluator.EvalError {
  compile_expr_limited(source, 0)
}

///|
/// Parses and lowers with a token budget (0 disables): sources longer
/// than `max_tokens` tokens are rejected at parse time, mirroring the
/// legacy parser's node budget (engine `set_limits` max_nodes).
pub fn compile_expr_limited(
  source : String,
  max_tokens : Int,
) -> @ast.AstNode? raise @evaluator.EvalError {
  let node = parse_limited(source, max_tokens) catch {
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
