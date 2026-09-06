// SPDX-License-Identifier: Apache-2.0
// Budget parity between engines + expr front-end parse budgets.
//
// Regression for two gaps found in review:
// 1. The Vm engine never enforced the eval-depth budget (max_depth) —
//    only the tree-walk engine raised "expression is too deep". The
//    Vm now annotates every instruction with its source-AST depth and
//    rejects the same executed paths the walk engine would.
// 2. The expr front-end parse path ignored max_nodes and had no
//    recursion guard, so the 4.1 safety budgets only applied to the
//    legacy jexl path.

///|
fn deep_unary(n : Int, tail : String) -> String {
  let mut s = tail
  for _ in 0..<n {
    s = "!" + s
  }
  s
}

///|
/// Evaluates `src` on a fresh engine in the given mode with the given
/// budgets; returns value or error message.
fn eval_limited(
  mode : @engine.EngineMode,
  src : String,
  ctx : @ast.Value,
  max_nodes : Int,
  max_depth : Int,
  max_steps : Int,
) -> Result[@ast.Value, String] {
  let inst = @engine.new()
  @engine.Engine::set_engine(inst, mode)
  @engine.Engine::set_limits(inst, max_nodes, max_depth, max_steps)
  Ok(@engine.Engine::eval(inst, src, ctx)) catch {
    @engine.EngineErr(msg) => Err(msg)
  }
}

///|
fn eval_expr_limited(
  mode : @engine.EngineMode,
  src : String,
  ctx : @ast.Value,
  max_nodes : Int,
  max_depth : Int,
  max_steps : Int,
) -> Result[@ast.Value, String] {
  let inst = @engine.new()
  @engine.Engine::set_engine(inst, mode)
  @engine.Engine::set_limits(inst, max_nodes, max_depth, max_steps)
  Ok(@engine.Engine::eval_expr(inst, src, ctx)) catch {
    @engine.EngineErr(msg) => Err(msg)
  }
}

///|
fn assert_same_result(
  rw : Result[@ast.Value, String],
  rv : Result[@ast.Value, String],
  label : String,
) -> Unit raise {
  match (rw, rv) {
    (Ok(a), Ok(b)) =>
      if !@ast.value_equal(a, b) {
        inspect(
          "walk=" + @evaluator.to_string(a) + " vm=" + @evaluator.to_string(b),
          content="parity (" + label + ")",
        )
      }
    (Err(m1), Err(m2)) =>
      if m1 != m2 {
        inspect(
          "walk-err=" + m1 + " vm-err=" + m2,
          content="parity-err (" + label + ")",
        )
      }
    (Ok(_), Err(m)) =>
      inspect("walk ok, vm error: " + m, content="parity (" + label + ")")
    (Err(m), Ok(_)) =>
      inspect("walk error: " + m + ", vm ok", content="parity (" + label + ")")
  }
}

///|
test "depth budget: walk and vm reject the same deep expressions" {
  let ctx = @ast.ObjectVal([("x", @ast.NumVal(1.0))])
  let deep = deep_unary(300, "x")
  // 300 nested unary ops exceed max_depth 100 on both engines, with
  // the identical error message.
  let rw = eval_limited(Walk, deep, ctx, 100000, 100, 1000000)
  let rv = eval_limited(Vm, deep, ctx, 100000, 100, 1000000)
  assert_same_result(rw, rv, "legacy deep unary rejected")
  match rw {
    Err(m) =>
      if m != "expression is too deep (more than 100 levels)" {
        inspect(m, content="walk too-deep message")
      }
    Ok(_) => inspect("ok", content="walk should raise")
  }
  // The same through the expr front end (parse + lower + both engines).
  let ew = eval_expr_limited(Walk, deep, ctx, 100000, 100, 1000000)
  let ev = eval_expr_limited(Vm, deep, ctx, 100000, 100, 1000000)
  assert_same_result(ew, ev, "expr deep unary rejected")
  // Generous depth: both succeed with equal values.
  let ok_w = eval_limited(Walk, deep, ctx, 100000, 1000, 1000000)
  let ok_v = eval_limited(Vm, deep, ctx, 100000, 1000, 1000000)
  assert_same_result(ok_w, ok_v, "deep unary accepted at depth 1000")
}

///|
test "depth budget: unexecuted deep branches are not rejected" {
  // Per-path accounting: a deep consequent that never runs must not
  // raise, on either engine (the check follows executed instructions).
  let ctx = @ast.ObjectVal([("x", @ast.NumVal(1.0))])
  let src = "if 0 { " + deep_unary(300, "x") + " } else { 7 }"
  let rw = eval_expr_limited(Walk, src, ctx, 100000, 100, 1000000)
  let rv = eval_expr_limited(Vm, src, ctx, 100000, 100, 1000000)
  assert_same_result(rw, rv, "dead deep branch")
  match rw {
    Ok(@ast.NumVal(d)) => assert_eq(d, 7.0)
    Ok(_) => inspect("wrong value", content="7")
    Err(m) => inspect(m, content="no error expected")
  }
}

///|
test "expr front end: parse budgets apply on eval_expr (max_nodes)" {
  let ctx = @ast.ObjectVal([])
  // 12000 sequence items => ~12002 AST nodes, over a configured
  // 5000-node budget AND over the default 10000 budget. Wide (not
  // deep), so the node limit is what fires.
  let mut big = "1"
  for _ in 0..<12000 {
    big = big + ";1"
  }
  let rw = eval_expr_limited(Walk, big, ctx, 5000, 100000, 1000000)
  let rv = eval_expr_limited(Vm, big, ctx, 5000, 100000, 1000000)
  assert_same_result(rw, rv, "over budget rejected on both")
  match rw {
    Err(m) =>
      if !m.contains("expression is too large") {
        inspect(m, content="too-large message")
      }
    Ok(_) => inspect("ok", content="expected too-large error")
  }
  // And with the DEFAULT engine budgets (no set_limits call): the
  // expr front end now honors the instance's max_nodes default.
  let inst = @engine.new()
  let r = Ok(@engine.Engine::eval_expr(inst, big, ctx)) catch {
    @engine.EngineErr(m) => Err(m)
  }
  match r {
    Err(m) =>
      if !m.contains("expression is too large") {
        inspect(m, content="default budget too-large message")
      }
    Ok(_) => inspect("ok", content="expected too-large error by default")
  }
  // A large but legal wide expression (300 items, ~600 nodes) still
  // evaluates identically on both engines.
  let mut ok = "1"
  for _ in 0..<300 {
    ok = ok + ";1"
  }
  let ow = eval_expr_limited(Walk, ok, ctx, 100000, 100000, 1000000)
  let ov = eval_expr_limited(Vm, ok, ctx, 100000, 100000, 1000000)
  assert_same_result(ow, ov, "legal wide expr ok")
  match ow {
    Ok(@ast.NumVal(d)) => assert_eq(d, 1.0)
    _ => inspect("bad", content="1")
  }
}

///|
test "expr front end: recursion guard rejects deep nesting" {
  let ctx = @ast.ObjectVal([("x", @ast.NumVal(1.0))])
  // 1500 nested parens: beyond the ~1000-level recursion guard (the
  // legacy parser rejects the same shape via its nesting budget).
  let mut deep = "x"
  for _ in 0..<1500 {
    deep = "(" + deep + ")"
  }
  let rw = eval_expr_limited(Walk, deep, ctx, 100000, 100000, 1000000)
  let rv = eval_expr_limited(Vm, deep, ctx, 100000, 100000, 1000000)
  assert_same_result(rw, rv, "deep parens rejected on both")
  match rw {
    Err(m) =>
      if !m.contains("too deeply nested") {
        inspect(m, content="nested message")
      }
    Ok(_) => inspect("ok", content="expected nesting error")
  }
  // Moderate nesting (300) still parses fine on both engines.
  let mut ok = "x"
  for _ in 0..<300 {
    ok = "(" + ok + ")"
  }
  let ow = eval_expr_limited(Walk, ok, ctx, 100000, 100000, 1000000)
  let ov = eval_expr_limited(Vm, ok, ctx, 100000, 100000, 1000000)
  assert_same_result(ow, ov, "moderate parens ok")
}
