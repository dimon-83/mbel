// SPDX-License-Identifier: Apache-2.0
// Builtins under the STANDARD dialect's typed value model.
//
// The legacy dialect only ever produces NumVal, so a builtin that
// pattern-matches on NumVal happens to work there while silently
// misbehaving on the standard dialect, where integer literals and integer
// arithmetic produce IntVal. `sort` (integer arrays came back unsorted)
// and `get` (integer indices returned the fallback) were both that bug,
// and neither was caught because the only tests drove them through the
// legacy path.
//
// Every case here therefore goes through `eval_expr` and asserts on BOTH
// engines, with explicit value kinds so an IntVal/NumVal regression is
// visible (they print identically).

///|
fn expect_expr_both(src : String, expected : @ast.Value, label : String) -> Unit {
  for mode in [@engine.Walk, @engine.Vm] {
    let inst = @engine.new()
    @engine.Engine::set_engine(inst, mode)
    let got = @engine.Engine::eval_expr(inst, src, @ast.ObjectVal([])) catch {
      @engine.EngineErr(msg) => abort(label + ": " + msg)
    }
    if !@ast.value_equal(got, expected) {
      let which = match mode {
        @engine.Walk => "walk"
        @engine.Vm => "vm"
      }
      abort(label + ": mismatch on " + which)
    }
  }
}

///|
test "sort orders integer arrays in the standard dialect" {
  expect_expr_both(
    "sort([3,1,2])",
    @ast.ArrayVal([@ast.IntVal(1L), @ast.IntVal(2L), @ast.IntVal(3L)]),
    "sort ints",
  )
  expect_expr_both(
    "sort([5,1,3,2,4,0])",
    @ast.ArrayVal([
      @ast.IntVal(0L),
      @ast.IntVal(1L),
      @ast.IntVal(2L),
      @ast.IntVal(3L),
      @ast.IntVal(4L),
      @ast.IntVal(5L),
    ]),
    "sort ints wider",
  )
  // Negative literals parse in the standard dialect (the legacy lexer
  // rejects `-` after `,`, which is a separate, locked behaviour).
  expect_expr_both(
    "sort([-1,-5,3])",
    @ast.ArrayVal([@ast.IntVal(-5L), @ast.IntVal(-1L), @ast.IntVal(3L)]),
    "sort negative ints",
  )
}

///|
test "sort keeps exact int64 order above 2^53" {
  // Routed through doubles these two collapse to the same value and the
  // order would be arbitrary.
  expect_expr_both(
    "sort([9007199254740993, 9007199254740992])",
    @ast.ArrayVal([@ast.IntVal(9007199254740992L), @ast.IntVal(9007199254740993L)]),
    "sort large ints",
  )
}

///|
test "sort still handles floats, strings and mixed numerics" {
  expect_expr_both(
    "sort([3.0,1.0,2.0])",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0), @ast.NumVal(3.0)]),
    "sort floats",
  )
  expect_expr_both(
    "sort([\"c\",\"a\",\"b\"])",
    @ast.ArrayVal([@ast.StrVal("a"), @ast.StrVal("b"), @ast.StrVal("c")]),
    "sort strings",
  )
  expect_expr_both(
    "sort([2,1.5,3])",
    @ast.ArrayVal([@ast.NumVal(1.5), @ast.IntVal(2L), @ast.IntVal(3L)]),
    "sort mixed numerics",
  )
  expect_expr_both("sort([])", @ast.ArrayVal([]), "sort empty")
}

///|
test "get accepts an integer index in the standard dialect" {
  expect_expr_both("get([3,1,2], 0)", @ast.IntVal(3L), "get first")
  expect_expr_both("get([3,1,2], 1)", @ast.IntVal(1L), "get middle")
  expect_expr_both("get([3,1,2], 2)", @ast.IntVal(2L), "get last")
  // Out of range and negative fall back to nil rather than an error.
  expect_expr_both("get([3,1,2], 9)", @ast.NullVal, "get out of range")
  expect_expr_both("get([3,1,2], -1)", @ast.NullVal, "get negative")
  // Explicit fallback argument.
  expect_expr_both("get([3,1,2], 9, \"x\")", @ast.StrVal("x"), "get fallback")
  // Float indices and map keys keep working.
  expect_expr_both("get([3.0,1.0], 1.0)", @ast.NumVal(1.0), "get float index")
  expect_expr_both("get({a:1}, \"a\")", @ast.IntVal(1L), "get map key")
  expect_expr_both("get({a:1}, \"z\")", @ast.NullVal, "get missing key")
}

///|
test "in uses the operator's equality under the typed value model" {
  // `1 == 1.0` is true, so membership has to agree. Bare strict element
  // matching made `1 in [1.0]` false while `1 == 1.0` was true — and the
  // checker accepts the expression (numbers are comparable in expr), so
  // the disagreement was invisible until it produced a wrong answer.
  expect_expr_both("1 in [1.0]", @ast.BoolVal(true), "int in float array")
  expect_expr_both("1.0 in [1]", @ast.BoolVal(true), "float in int array")
  expect_expr_both("1 in [1]", @ast.BoolVal(true), "int in int array")
  expect_expr_both("1 in [2, 3]", @ast.BoolVal(false), "int miss in int array")
  expect_expr_both("1 in [1.5]", @ast.BoolVal(false), "int miss in float array")
  expect_expr_both("nil in [1]", @ast.BoolVal(false), "nil in int array")
  // Exact int64 comparison: these two collapse to the same double, so a
  // numeric-coercion path that went through doubles would answer true.
  expect_expr_both(
    "9007199254740993 in [9007199254740992]",
    @ast.BoolVal(false),
    "distinct large int64 members",
  )
  expect_expr_both(
    "9007199254740992 in [9007199254740992]",
    @ast.BoolVal(true),
    "equal large int64 members",
  )
}
