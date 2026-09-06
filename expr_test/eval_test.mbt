// SPDX-License-Identifier: Apache-2.0
// expr front-end evaluation tests: expr syntax -> lower -> legacy AST
// -> both engines. Every case asserts Walk and Vm agree.

///|
let eval_ctx : @ast.Value = @ast.ObjectVal([
  ("x", @ast.NumVal(3.0)),
  ("age", @ast.NumVal(36.0)),
  ("name", @ast.StrVal("Archer")),
  (
    "users",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Bob")), ("age", @ast.NumVal(15.0))]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
  ),
  (
    "nums",
    @ast.ArrayVal([
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
      @ast.NumVal(5.0),
    ]),
  ),
])

///|
fn expected_str(v : @ast.Value) -> String {
  @evaluator.to_string(v)
}

///|
fn eval_both(
  src : String,
) -> (@ast.Value, @ast.Value) raise @engine.EngineError {
  let w = @engine.new()
  let v = @engine.new()
  @engine.Engine::set_engine(v, Vm)
  // expr-dialect entry point: new front-end + dual-engine core
  let rw = @engine.Engine::eval_expr(w, src, eval_ctx)
  let rv = @engine.Engine::eval_expr(v, src, eval_ctx)
  (rw, rv)
}

///|
fn expect_eval(
  src : String,
  expected : @ast.Value,
  label : String,
) -> Unit raise {
  let (rw, rv) = eval_both(src) catch {
    @engine.EngineErr(msg) => abort(label + " failed: " + msg)
  }
  let nan_eq = match (rw, rv) {
    (@ast.NumVal(a), @ast.NumVal(b)) => a == b || (a != a && b != b)
    (_, _) => false
  }
  if !@ast.value_equal(rw, expected) {
    inspect(@evaluator.to_string(rw), content=expected_str(expected))
  }
  if !(@ast.value_equal(rw, rv) || nan_eq) {
    inspect(
      "walk=" + @evaluator.to_string(rw) + " vm=" + @evaluator.to_string(rv),
      content="identical",
    )
  }
}

///|
fn expect_eval_err(src : String, frag : String, label : String) -> Unit raise {
  try {
    ignore(eval_both(src))
    abort(label + ": expected error")
  } catch {
    @engine.EngineErr(msg) =>
      if !msg.contains(frag) {
        inspect(msg, content="error containing '" + frag + "'")
      }
  }
}

// --- expr-only literals evaluated through lowering ---

///|
test "expr eval: literal family" {
  expect_eval("0x2A + 0b1000", @ast.NumVal(50.0), "hex+bin")
  expect_eval("10_000 / 4", @ast.NumVal(2500.0), "underscore")
  expect_eval("2 ** 10", @ast.NumVal(1024.0), "power")
  expect_eval("14 / 2", @ast.NumVal(7.0), "division (// is a comment in expr)")
  expect_eval("1..5 == [1,2,3,4,5]", @ast.BoolVal(true), "range eq")
}

///|
test "expr eval: comparisons and chains" {
  expect_eval("1 < x && x < 10", @ast.BoolVal(true), "explicit chain")
  expect_eval("0 < 1 < 2", @ast.BoolVal(true), "true chain")
  expect_eval("2 < 1 < 5", @ast.BoolVal(false), "false chain")
  expect_eval("1 + 2 == 3", @ast.BoolVal(true), "arith eq")
}

///|
test "expr eval: nil coalescing and members" {
  expect_eval("name ?? \"none\"", @ast.StrVal("Archer"), "coalesce value")
  expect_eval("missing ?? \"none\"", @ast.StrVal("none"), "coalesce missing")
  expect_eval(
    "user?.name ?? \"nobody\"",
    @ast.StrVal("nobody"),
    "optional chain nil-safe",
  )
}

///|
test "expr eval: not-suffixed operators" {
  expect_eval("x not in [1, 2]", @ast.BoolVal(true), "not in")
  expect_eval("name not matches \"^L\"", @ast.BoolVal(true), "not matches")
}

///|
test "expr eval: predicates through braces and bare form" {
  expect_eval(
    "filter(users, {.age >= 18})",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "brace pred",
  )
  expect_eval(
    "map(nums, # * 2)",
    @ast.ArrayVal([
      @ast.NumVal(2.0),
      @ast.NumVal(4.0),
      @ast.NumVal(6.0),
      @ast.NumVal(8.0),
      @ast.NumVal(10.0),
    ]),
    "map double",
  )
  expect_eval(
    "filter(users, {#.age >= 18})",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "explicit pointer member",
  )
  expect_eval(
    "filter(users, .age >= 18)",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "relative field",
  )
  expect_eval("count(nums, # > 2)", @ast.NumVal(3.0), "count")
  expect_eval("sum(nums, # * #)", @ast.NumVal(55.0), "sum squares")
  expect_eval("reduce(nums, #acc + #)", @ast.NumVal(15.0), "reduce")
  expect_eval("findIndex(nums, # == 4)", @ast.NumVal(3.0), "findIndex")
}

///|
test "expr eval: unknown pointer suffix is a compile error" {
  // expr supports only `#`, `#index`, `#acc` — `#age` must not
  // silently read as the whole element.
  expect_eval_err(
    "filter(users, {#age >= 18})", "unknown pointer", "bad pointer",
  )
}

///|
test "expr eval: aggregates inside range and nested" {
  expect_eval("sum(1..100)", @ast.NumVal(5050.0), "sum range")
  expect_eval("count(filter(nums, # > 2))", @ast.NumVal(3.0), "count filter")
}

// --- unsupported-but-parsed syntax surfaces clean errors ---

///|
test "expr eval: let/sequence/slice report not-yet-evaluable" {
  expect_eval_err("let x = 1; x", "not yet evaluable", "let")
  expect_eval_err("nums[1:3]", "not yet evaluable", "slice")
}

///|
test "expr eval: parse errors surface with location" {
  expect_eval_err("1 +", "parse error at", "incomplete")
}
