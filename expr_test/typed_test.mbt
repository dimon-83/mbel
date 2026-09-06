// SPDX-License-Identifier: Apache-2.0
// Stage 4.4.3 typed value model: expr front-end evaluations are typed
// (IntVal for integers) while the legacy Jexl path stays double-based.
// These tests lock the typed results explicitly — value equality
// alone cannot (IntVal 50 and NumVal 50.0 print identically).

///|
fn typed_of(src : String) -> String raise {
  let i = @engine.new()
  try {
    let v = @engine.Engine::eval_expr(i, src, @ast.ObjectVal([]))
    match v {
      @ast.IntVal(x) => "int:" + x.to_string()
      @ast.NumVal(d) =>
        if d != d {
          "float:nan"
        } else if d == 1.0 / 0.0 {
          "float:inf"
        } else if d == -1.0 / 0.0 {
          "float:-inf"
        } else {
          "float:" + d.to_string()
        }
      @ast.BoolVal(b) => "bool:" + (if b { "true" } else { "false" })
      @ast.StrVal(s) => "str:" + s
      other => "other:" + @evaluator.to_string(other)
    }
  } catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
fn expect_typed(src : String, expected : String, label : String) -> Unit raise {
  let got = typed_of(src)
  inspect(got, content=expected)
}

///|
test "typed: integer literals and arithmetic stay int; / is float" {
  expect_typed("42", "int:42", "literal")
  expect_typed("0x2A + 0b1000", "int:50", "hex+bin int")
  expect_typed("2 + 3 * 4", "int:14", "int arithmetic")
  expect_typed("7 / 2", "float:3.5", "division is float")
  expect_typed("7 % 3", "int:1", "int modulo")
  expect_typed("-7 % 3", "int:-1", "modulo sign of dividend")
  expect_typed("7 % -3", "int:1", "modulo sign of dividend (2)")
  expect_typed("2 ** 10", "float:1024", "power is float")
  expect_typed("-2 ** 2", "float:-4", "-(2**2) float")
  expect_typed("1.5 + 2", "float:3.5", "int+float -> float")
}

///|
test "typed: int64 wraps like Go; overflow literals are parse errors" {
  expect_typed(
    "9223372036854775807 + 1", "int:-9223372036854775808", "max+1 wraps",
  )
  expect_typed("9223372036854775807 * 2", "int:-2", "max*2 wraps")
  expect_typed("5 % 0", "ERR:integer divide by zero", "%0 errors")
  expect_typed("1 / 0", "float:inf", "1/0 is +Inf (float)")
  expect_typed("0 / 0", "float:nan", "0/0 is NaN")
  expect_typed(
    "9223372036854775808", "ERR:parse error at 1:1: invalid integer literal: value out of range",
    "literal beyond int64 is a parse error",
  )
}

///|
test "typed: equality and comparisons follow expr kinds" {
  expect_typed("1 == 1", "bool:true", "int==int")
  expect_typed("1 == 1.0", "bool:true", "int==float promotes")
  expect_typed("1 == \"1\"", "bool:false", "int==string false")
  expect_typed("1 < 2", "bool:true", "int ordering exact")
  expect_typed("1 < 1.5", "bool:true", "int<float promotes")
  expect_typed(
    "1 + \"a\"", "ERR:invalid operation: int + string", "mixed + errors",
  )
  expect_typed(
    "\"a\" + 1", "ERR:invalid operation: string + int", "mixed + errors 2",
  )
  expect_typed(
    "\"a\" < 1", "ERR:invalid operation: string < int", "mixed ordering errors",
  )
  expect_typed(
    "1.5 % 1", "ERR:invalid operation: float % int", "float modulo errors",
  )
}

///|
test "typed: type() and ranges report integers" {
  expect_typed("type(5)", "str:int", "type of int")
  expect_typed("type(5.0)", "str:number", "float still number (legacy name)")
  expect_typed("type(5 + 2)", "str:int", "type of int sum")
  expect_typed("len(1..5)", "float:5", "range len")
  let i = @engine.new()
  let r = @engine.Engine::eval_expr(i, "1..3", @ast.ObjectVal([])) catch {
    @engine.EngineErr(m) => abort("range: " + m)
  }
  match r {
    @ast.ArrayVal(xs) => {
      let typed_elem = match xs[0] {
        @ast.IntVal(_) => true
        _ => false
      }
      if xs.length() != 3 || !typed_elem {
        inspect(@evaluator.to_string(r), content="int range")
      }
    }
    _ => inspect("bad", content="array")
  }
}
