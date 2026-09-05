// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// jexl_test: blackbox tests for the top-level jexl package.
// Ported from Jexl's __tests__/lib/Jexl.test.js + Expression.test.js.

///|
/// Value builders.
fn v_num(d : Double) -> @ast.Value {
  @ast.NumVal(d)
}

///|
fn v_str(s : String) -> @ast.Value {
  @ast.StrVal(s)
}

///|
fn v_bool(b : Bool) -> @ast.Value {
  @ast.BoolVal(b)
}

///|
fn v_arr(xs : Array[@ast.Value]) -> @ast.Value {
  @ast.ArrayVal(xs)
}

///|
fn v_obj(pairs : Array[(String, @ast.Value)]) -> @ast.Value {
  @ast.ObjectVal(pairs)
}

///|
fn expect_eq(
  actual : @ast.Value,
  expected : @ast.Value,
  label : String,
) -> Unit {
  if !@ast.value_equal(actual, expected) {
    abort("mismatch: " + label)
  }
}

///|
/// Evals an expression on a fresh instance and compares the result.
fn expect_eval(
  expr : String,
  context : @ast.Value,
  expected : @ast.Value,
) -> Unit {
  let inst = @jexl.new_jexl()
  let result = @jexl.Jexl::eval(inst, expr, context) catch {
    @jexl.JexlErr(msg) => abort("eval failed for '" + expr + "': " + msg)
  }
  expect_eq(result, expected, expr)
}

///|
/// Expects evaluation to raise with a message containing `frag`.
fn expect_eval_err(expr : String, context : @ast.Value, frag : String) -> Unit {
  let inst = @jexl.new_jexl()
  try {
    ignore(@jexl.Jexl::eval(inst, expr, context))
    abort("expected error for '" + expr + "'")
  } catch {
    @jexl.JexlErr(msg) =>
      if !msg.contains(frag) {
        abort("error message '" + msg + "' lacks '" + frag + "'")
      }
  }
}

// --- compile / createExpression ---

///|
test "compile returns an evaluatable expression" {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(inst, "2/2") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let result = @jexl.Expression::eval(expr_obj, v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(result, v_num(1.0), "2/2")
}

///|
test "compile throws on invalid tokens" {
  let inst = @jexl.new_jexl()
  try {
    ignore(@jexl.Jexl::compile(inst, "2 & 2"))
    abort("expected compile error")
  } catch {
    @jexl.JexlErr(msg) =>
      assert_true(msg.contains("Invalid expression token: &"))
  }
}

///|
test "createExpression does not compile" {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::create_expression(inst, "2 wouldFail &^% ..4")
  // evaluation would fail at compile time; construction itself is fine
  try {
    ignore(@jexl.Expression::eval(expr_obj, v_obj([])))
    abort("expected error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
}

///|
test "Expression eval lazily compiles once" {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::create_expression(inst, "2*2")
  let r1 = @jexl.Expression::eval(expr_obj, v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let r2 = @jexl.Expression::eval(expr_obj, v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(r1, v_num(4.0), "2*2 first")
  expect_eq(r2, v_num(4.0), "2*2 second")
}

// --- eval ---

///|
test "eval resolves on success" {
  expect_eval("2+2", v_obj([]), v_num(4.0))
}

///|
test "eval raises on parse error" {
  expect_eval_err("2++2", v_obj([]), "unexpected")
}

///|
test "eval passes context" {
  expect_eval("foo", v_obj([("foo", v_str("bar"))]), v_str("bar"))
}

///|
test "filters collections as expected (issue #61)" {
  let context = v_obj([
    (
      "a",
      v_arr([
        v_obj([("b", v_str("A"))]),
        v_obj([("b", v_str("B"))]),
        v_obj([("b", v_str("C"))]),
      ]),
    ),
  ])
  expect_eval(
    "a[.b in [\"A\",\"B\"]]",
    context,
    v_arr([v_obj([("b", v_str("A"))]), v_obj([("b", v_str("B"))])]),
  )
}

///|
test "evalSync semantics (same as eval — synchronous)" {
  expect_eval("2+2", v_obj([]), v_num(4.0))
  expect_eval("foo", v_obj([("foo", v_str("bar"))]), v_str("bar"))
  expect_eval_err("2++2", v_obj([]), "unexpected")
}

///|
test "throws if transform fails" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transform(inst, "abort", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value raise @evaluator.EvalError {
    raise @evaluator.EvalErr("oops")
  })
  try {
    ignore(@jexl.Jexl::eval(inst, "\"hello\"|abort", v_obj([])))
    abort("expected error")
  } catch {
    @jexl.JexlErr(msg) => assert_true(msg.contains("oops"))
  }
}

///|
test "throws if nested transform fails" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transform(inst, "q1", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value raise @evaluator.EvalError {
    raise @evaluator.EvalErr("oops")
  })
  @jexl.Jexl::add_binary_op(inst, "is", 100, fn(
    a : @ast.Value,
    b : @ast.Value,
  ) -> @ast.Value {
    v_bool(true)
  })
  try {
    ignore(@jexl.Jexl::eval(inst, "\"hello\"|q1 is asdf", v_obj([])))
    abort("expected error")
  } catch {
    @jexl.JexlErr(msg) => assert_true(msg.contains("oops"))
  }
}

///|
test "early-exits boolean AND when the left is false (issue #64)" {
  let context = v_obj([("a", @ast.NullVal)])
  expect_eval("a != null && a.b", context, v_bool(false))
}

// --- addFunction / getFunction ---

///|
test "allows functions to be defined" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_function(inst, "sayHi", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_str("Hello")
  })
  expect_eq(
    @jexl.Jexl::eval(inst, "sayHi()", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_str("Hello"),
    "sayHi()",
  )
}

///|
test "allows functions to be retrieved" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_function(inst, "ret2", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(2.0)
  })
  match @jexl.Jexl::get_function(inst, "ret2") {
    Some(f) => expect_eq(f([]), v_num(2.0), "ret2()")
    None => abort("get_function returned None")
  }
}

///|
test "allows functions to be set in batch" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_functions(inst, [
    (
      "add1",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        @ast.NumVal(@evaluator.to_number(args[0]) + 1.0)
      },
    ),
    (
      "add2",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        @ast.NumVal(@evaluator.to_number(args[0]) + 2.0)
      },
    ),
  ])
  expect_eq(
    @jexl.Jexl::eval(inst, "add1(add2(2))", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_num(5.0),
    "add1(add2(2))",
  )
}

// --- addTransform ---

///|
test "allows transforms to be defined" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transform(inst, "toCase", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    let val = args[0]
    let opts = args[1]
    let is_upper = match opts {
      @ast.ObjectVal(pairs) => {
        let mut found = false
        for pair in pairs {
          let (k, v) = pair
          if k == "case" {
            found = match v {
              @ast.StrVal(s) => s == "upper"
              _ => false
            }
          }
        }
        found
      }
      _ => false
    }
    match val {
      @ast.StrVal(s) =>
        v_str(if is_upper { to_upper_ascii(s) } else { to_lower_ascii(s) })
      _ => val
    }
  })
  expect_eq(
    @jexl.Jexl::eval(inst, "\"hello\"|toCase({case:\"upper\"})", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_str("HELLO"),
    "toCase upper",
  )
}

///|
fn to_upper_ascii(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'a' && c <= 'z' {
      out.write_char((c.to_int() - 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn to_lower_ascii(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'A' && c <= 'Z' {
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
test "allows transforms to be retrieved" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transform(inst, "ret2", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(2.0)
  })
  match @jexl.Jexl::get_transform(inst, "ret2") {
    Some(f) => expect_eq(f([]), v_num(2.0), "ret2 transform")
    None => abort("get_transform returned None")
  }
}

///|
test "allows transforms to be set in batch" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transforms(inst, [
    (
      "add1",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        @ast.NumVal(@evaluator.to_number(args[0]) + 1.0)
      },
    ),
    (
      "add2",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        @ast.NumVal(@evaluator.to_number(args[0]) + 2.0)
      },
    ),
  ])
  expect_eq(
    @jexl.Jexl::eval(inst, "2|add1|add2", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_num(5.0),
    "2|add1|add2",
  )
}

// --- addBinaryOp ---

///|
test "allows binaryOps to be defined" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_binary_op(inst, "_=", 20, fn(
    a : @ast.Value,
    b : @ast.Value,
  ) -> @ast.Value {
    v_bool(
      to_lower_ascii(@evaluator.to_string(a)) ==
      to_lower_ascii(@evaluator.to_string(b)),
    )
  })
  expect_eq(
    @jexl.Jexl::eval(inst, "\"FoO\" _= \"fOo\"", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_bool(true),
    "_=",
  )
}

///|
test "observes precedence on binaryOps" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_binary_op(inst, "**", 0, fn(
    a : @ast.Value,
    b : @ast.Value,
  ) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(a) * 2.0 + @evaluator.to_number(b) * 2.0)
  })
  @jexl.Jexl::add_binary_op(inst, "***", 1000, fn(
    a : @ast.Value,
    b : @ast.Value,
  ) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(a) * 2.0 + @evaluator.to_number(b) * 2.0)
  })
  let r1 = @jexl.Jexl::eval(inst, "1 + 2 ** 3 + 4", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let r2 = @jexl.Jexl::eval(inst, "1 + 2 *** 3 + 4", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(r1, v_num(20.0), "low precedence **")
  expect_eq(r2, v_num(15.0), "high precedence ***")
}

///|
test "allows binaryOps with manual operand evaluation" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_binary_op_manual(inst, "$$", 50, fn(
    l : @evaluator.Lazy,
    r : @evaluator.Lazy,
  ) -> @ast.Value raise @evaluator.EvalError {
    let lv = l()
    if @evaluator.to_number(lv) > 0.0 {
      lv
    } else {
      r()
    }
  })
  let cell : Array[Int] = [0]
  @jexl.Jexl::add_transform(inst, "inc", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    cell[0] = cell[0] + 1
    args[0]
  })
  let r1 = @jexl.Jexl::eval(inst, "-2|inc $$ 5|inc", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("EVALERR: " + msg)
  }
  expect_eq(r1, v_num(5.0), "$$ left falsy path")
  if cell[0] != 2 {
    abort("count after first = " + cell[0].to_string())
  }
  cell[0] = 0
  let r2 = @jexl.Jexl::eval(inst, "2|inc $$ -5|inc", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(r2, v_num(2.0), "$$ left truthy path")
  assert_eq(cell[0], 1)
}

// --- addUnaryOp / removeOp ---

///|
test "allows unaryOps to be defined" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_unary_op(inst, "~", fn(v : @ast.Value) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(v).floor())
  })
  expect_eq(
    @jexl.Jexl::eval(inst, "~5.7 + 5", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    },
    v_num(10.0),
    "~5.7+5",
  )
}

///|
test "allows binaryOps to be removed" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::remove_op(inst, "+")
  try {
    ignore(@jexl.Jexl::eval(inst, "1+2", v_obj([])))
    abort("expected error")
  } catch {
    @jexl.JexlErr(msg) => assert_true(to_lower_ascii(msg).contains("invalid"))
  }
}

///|
test "allows unaryOps to be removed" {
  let inst = @jexl.new_jexl()
  @jexl.Jexl::remove_op(inst, "!")
  try {
    ignore(@jexl.Jexl::eval(inst, "!true", v_obj([])))
    abort("expected error")
  } catch {
    @jexl.JexlErr(msg) => assert_true(to_lower_ascii(msg).contains("invalid"))
  }
}

// --- Expression.test.js cases ---

///|
test "Expression compiles '2 % 2' and evaluates to 0" {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(inst, "2 % 2") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let result = @jexl.Expression::eval_default(expr_obj) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(result, v_num(0.0), "2 % 2")
}

///|
test "Expression re-compiles after grammar changes" {
  let inst = @jexl.new_jexl()
  // 'a/a' cannot be constant-folded (identifier), so removing '/'
  // surfaces at re-compile time; a foldable '2/2' would legitimately
  // keep its compiled value (that is what the optimizer is for).
  let expr_obj = @jexl.Jexl::create_expression(inst, "a/a")
  let before = @jexl.Expression::eval(expr_obj, v_obj([("a", v_num(2.0))])) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  expect_eq(before, v_num(1.0), "a/a before")
  @jexl.Jexl::remove_op(inst, "/")
  try {
    ignore(@jexl.Expression::eval(expr_obj, v_obj([("a", v_num(2.0))])))
    abort("expected error after removing '/'")
  } catch {
    @jexl.JexlErr(_) => ()
  }
}
