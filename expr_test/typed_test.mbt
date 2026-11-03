// SPDX-License-Identifier: Apache-2.0
// Stage 4.4.3 typed value model: expr front-end evaluations are typed
// (IntVal for integers) while the legacy Jexl path stays double-based.
// These tests lock the typed results explicitly — value equality
// alone cannot (IntVal 50 and NumVal 50.0 print identically).

///|
fn typed_render(v : @ast.Value) -> String {
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
}

///|
fn typed_of(src : String) -> String raise {
  let i = @engine.new()
  typed_render(@engine.Engine::eval_expr(i, src, @ast.ObjectVal([]))) catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
fn typed_of_env(src : String, ctx_json : String) -> String raise {
  // 0002 P2a (Decision 4 = (a)): env JSON numbers integer-valued within
  // ±(2^53 - 1) cross the shared boundary as IntVal.
  let j = @json.parse(ctx_json) catch {
    _ => abort("bad test ctx json: " + ctx_json)
  }
  let ctx = @builtin.json_to_value(j)
  let i = @engine.new()
  typed_render(@engine.Engine::eval_expr(i, src, ctx)) catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
fn expect_typed(src : String, expected : String, label : String) -> Unit raise {
  let got = typed_of(src)
  inspect(got, content=expected)
}

///|
fn expect_typed_env(
  src : String,
  ctx_json : String,
  expected : String,
  label : String,
) -> Unit raise {
  let got = typed_of_env(src, ctx_json)
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
  // The standard dialect now reports expr's "float"; the legacy dialect
  // keeps the JS name "number" (see engine_test/builtin_test.mbt).
  expect_typed("type(5.0)", "str:float", "type of float")
  expect_typed("type(5 + 2)", "str:int", "type of int sum")
  expect_typed("len(1..5)", "int:5", "range len")
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

///|
test "typed: builtin returns follow expr (len/int/index/count/sum/abs/min/max)" {
  expect_typed("abs(-5)", "int:5", "abs int")
  expect_typed("min(3, 1, 2)", "int:1", "min ints")
  expect_typed("max([1, 5, 3])", "int:5", "max int array")
  expect_typed("sum(1..5)", "int:15", "sum int range")
  expect_typed("count([true, true, false])", "int:2", "count bools")
  expect_typed("len(\"hello\")", "int:5", "len")
  expect_typed("indexOf(\"hello\", \"ll\")", "int:2", "indexOf")
  expect_typed("int(3.9)", "int:3", "int truncates")
  expect_typed("int(-3.9)", "int:-3", "int truncates neg")
  expect_typed("min(3, 1.5)", "float:1.5", "min mixed promotes float")
  // legacy lock: builtin_test still covers NumVal inputs (sum over a
  // float ctx stays float there)
}

///|
test "typed: toJSON emits exact int64 digits" {
  expect_typed(
    "toJSON(9223372036854775807)", "str:9223372036854775807", "exact max int64",
  )
  expect_typed(
    "toJSON([1, 9223372036854775807])", "str:[1,9223372036854775807]", "nested exact int64",
  )
  expect_typed("toJSON(1.5 + 1)", "str:2.5", "float json ok")
}

///|
test "typed: JSON boundary maps integer-valued env numbers to IntVal (P2a)" {
  // 0002 P2a, Decision 4 = (a): `5` and `5.0` are indistinguishable at the
  // Json layer (core keeps the raw repr only for non-round-trippable
  // numbers), so both map to IntVal. The bound is ±(2^53 - 1): at 2^53 and
  // beyond, doubles alias neighbors (2^53 + 1 parses to the same double as
  // 2^53), so such numbers stay NumVal rather than claim false exactness.
  expect_typed_env(
    "n + 1", "{\"n\":5}", "int:6", "env int arithmetic stays int",
  )
  expect_typed_env("type(n)", "{\"n\":5}", "str:int", "env 5 is IntVal")
  expect_typed_env("type(n)", "{\"n\":5.0}", "str:int", "env 5.0 is IntVal too")
  expect_typed_env(
    "n + 0.5", "{\"n\":5}", "float:5.5", "env int + float promotes",
  )
  expect_typed_env(
    "type(n)", "{\"n\":5.5}", "str:float", "fractional stays NumVal",
  )
  expect_typed_env(
    "type(n)", "{\"n\":9.2e18}", "str:float", "beyond 2^53-1 stays NumVal",
  )
  expect_typed_env(
    "type(n)", "{\"n\":9007199254740993}", "str:float", "2^53+1 double-aliases to 2^53; stays NumVal",
  )
  expect_typed_env(
    "type(n)", "{\"n\":9007199254740991}", "str:int", "2^53-1 boundary maps",
  )
  expect_typed_env(
    "type(n)", "{\"n\":9007199254740992}", "str:float", "2^53 itself arrives repr-tagged from int literals; stays NumVal",
  )
  expect_typed_env(
    "sum(xs)", "{\"xs\":[1,2,3]}", "int:6", "sum over env ints stays int",
  )
  expect_typed_env(
    "sum(xs)", "{\"xs\":[1,2,3.5]}", "float:6.5", "sum promotes on float",
  )
  expect_typed_env(
    "a * b", "{\"a\":4294967296,\"b\":2147483648}", "int:-9223372036854775808", "env int multiply wraps (Go parity; documented, Decision 5)",
  )
  expect_typed_env(
    "n == 5", "{\"n\":5}", "bool:true", "int == float cross-class",
  )
}
