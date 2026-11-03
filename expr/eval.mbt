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

///|
/// Parses, type-checks, and lowers an expr source with a token budget.
/// Raises EvalError with expr's compile-mode error text for type
/// violations (the strict/Compile-mode counterpart of compile_expr).
pub fn compile_expr_checked_limited(
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
  check(node) catch {
    CheckErr(msg, line, col) =>
      raise @evaluator.EvalErr(positioned(msg, line, col, source))
  }
  let lowered = lower(node) catch {
    LowerErr(msg) => raise @evaluator.EvalErr(msg)
  }
  Some(lowered)
}

///|
/// Parses, type-checks with a call-resolution context, and lowers an
/// expr source with a token budget. Checked expressions on an instance
/// with registered user functions use this entry so call sites see the
/// same symbol table as the function bodies.
pub fn compile_expr_checked_with_functions_limited(
  source : String,
  max_tokens : Int,
  functions : Array[(String, Int)],
  callables : Array[String],
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
  let ctx : CheckCtx = {
    functions,
    callables,
    strict_names: false,
    strict_calls: true,
  }
  check_with_ctx(node, ctx) catch {
    CheckErr(msg, line, col) =>
      raise @evaluator.EvalErr(positioned(msg, line, col, source))
  }
  let lowered = lower(node) catch {
    LowerErr(msg) => raise @evaluator.EvalErr(msg)
  }
  Some(lowered)
}

///|
/// Parses, type-checks, and lowers a user-function body (P2). The
/// parameter list is the body's lexical scope and the symbol table is
/// complete before checking, so unknown names/calls and arity
/// mismatches are compile errors. Errors carry the owning function's
/// name and a position inside its body.
pub fn compile_function_body_checked_limited(
  name : String,
  body : String,
  params : Array[String],
  functions : Array[(String, Int)],
  callables : Array[String],
  max_tokens : Int,
) -> @ast.AstNode raise @evaluator.EvalError {
  let node = parse_limited(body, max_tokens) catch {
    ParseErrExpr(msg, line, col) =>
      raise @evaluator.EvalErr(
        "function \"" +
        name +
        "\": parse error at " +
        line.to_string() +
        ":" +
        col.to_string() +
        ": " +
        msg,
      )
  }
  check_function_body(node, params, functions, callables) catch {
    CheckErr(msg, line, col) =>
      raise @evaluator.EvalErr(
        "function \"" + name + "\": " + positioned(msg, line, col, body),
      )
  }
  let lowered = lower(node) catch {
    LowerErr(msg) =>
      raise @evaluator.EvalErr("function \"" + name + "\": " + msg)
  }
  lowered
}

///|
/// Formats a positioned compile-mode error the way expr's FileError
/// does: "msg (L:C)" plus the source line and a caret column:
///
///   invalid operation: + (mismatched types int and string) (1:3)
///    | 1 + "a"
///    | ..^
fn positioned(
  msg : String,
  line : Int,
  col : Int,
  source : String,
) -> String {
  let lines = source.split("\n").map(fn(v) { v.to_owned() }).to_array()
  let idx = line - 1
  let mut out = msg + " (" + line.to_string() + ":" + col.to_string() + ")"
  if idx >= 0 && idx < lines.length() {
    // tabs render as spaces in expr's snippet
    let src_line = lines[idx].replace(old="\t", new=" ")
    out = out + "\n | " + src_line + "\n | "
    let mut dots = ""
    for _ in 0..<(col - 1) {
      dots = dots + "."
    }
    out = out + dots + "^"
  }
  out
}
