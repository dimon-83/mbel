// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// jexl_test: resource budget tests (stage 4.1, mirroring expr's
// MaxNodes + memory protections).

///|
fn repeat_str(s : String, n : Int) -> String {
  let out = StringBuilder::new()
  for _ in 0..<n {
    out.write_string(s)
  }
  out.to_string()
}

///|
fn expect_jexl_err(
  inst : @engine.Engine,
  expr : String,
  frag : String,
  label : String,
) -> Unit {
  try {
    ignore(@engine.Engine::eval(inst, expr, @ast.ObjectVal([])))
    abort("expected budget error: " + label)
  } catch {
    @engine.EngineErr(msg) =>
      if !msg.contains(frag) {
        abort(
          "budget error message '" +
          msg +
          "' lacks '" +
          frag +
          "' (" +
          label +
          ")",
        )
      }
  }
}

///|
test "parser rejects expressions over the default node limit" {
  let inst = @engine.new()
  // 11001 '1+' pairs = 22001 tokens > the default 10000; no nesting,
  // so the node budget is what fires.
  let expr = repeat_str("1+", 11001) + "1"
  expect_jexl_err(inst, expr, "too large", "default node limit")
}

///|
test "parser rejects deeply nested subexpressions" {
  let inst = @engine.new()
  // 1500 nested parens — under the node budget but over the nesting
  // budget (wasm stack protection).
  let expr = repeat_str("(", 1500) + "1" + repeat_str(")", 1500)
  expect_jexl_err(inst, expr, "too deeply nested", "nesting budget")
}

///|
test "node limit is configurable" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 20, 0, 0)
  // 15 tokens — under the 20 limit.
  let ok = @engine.Engine::eval(inst, "1+2+3+4+5+6+7", @ast.ObjectVal([])) catch {
    @engine.EngineErr(msg) => abort("unexpected error: " + msg)
  }
  assert_true(@ast.value_equal(ok, @ast.NumVal(28.0)))
  // 21 tokens — over the 20 limit.
  expect_jexl_err(inst, "1+2+3+4+5+6+7+8+9+10+11", "too large", "node limit 20")
}

///|
test "eval rejects expressions deeper than the depth limit" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 50, 0)
  // 60-level identifier chain: eval recurses once per level.
  let deep = repeat_str("a.", 60) + "b"
  expect_jexl_err(inst, deep, "too deep", "depth limit 50")
}

///|
test "eval rejects expressions past the step budget" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 0, 20)
  // Allocation-point charging (expr memGrow semantics): 20 array
  // literals + 19 concatenation allocations = 39 units > 20.
  let expr = repeat_str("[0]+", 20) + "[0]"
  expect_jexl_err(inst, expr, "budget", "step budget 20")
}

///|
test "filter cannot amplify work past the step budget" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 0, 5)
  // Relative filtering charges per subject element: a 10-element
  // array costs 10 units, exceeding the 5 budget before any predicate
  // runs — filters cannot scan past the limit.
  let arr_vals : Array[@ast.Value] = []
  for i in 1..<11 {
    arr_vals.push(@ast.NumVal(i.to_double()))
  }
  let ctx = @ast.ObjectVal([("arr", @ast.ArrayVal(arr_vals))])
  let expr = "arr[.a > 2]"
  try {
    ignore(@engine.Engine::eval(inst, expr, ctx))
    abort("expected budget error: shared budget across filter")
  } catch {
    @engine.EngineErr(msg) =>
      if !msg.contains("budget") {
        abort("budget error message '" + msg + "' lacks 'budget'")
      }
  }
}

///|
test "disabling limits restores unbounded evaluation" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 0, 0)
  let r = @engine.Engine::eval(inst, "1+2+3+4+5+6+7+8+9+10", @ast.ObjectVal([])) catch {
    @engine.EngineErr(msg) => abort("unexpected error: " + msg)
  }
  assert_true(@ast.value_equal(r, @ast.NumVal(55.0)))
}
