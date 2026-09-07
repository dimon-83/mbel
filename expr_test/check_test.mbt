// SPDX-License-Identifier: Apache-2.0
// Stage 4.4.4 checker (phase 1) — expr Compile-mode type errors.
// eval_expr stays Eval-mode (no static checks); the strict entry
// eval_expr_checked applies the checker first. All error messages
// follow expr's compile-mode wording.

///|
fn checked(src : String) -> String raise {
  let w = @engine.new()
  let v = @engine.new()
  @engine.Engine::set_engine(v, Vm)
  let ctx = @ast.ObjectVal([
    ("x", @ast.NumVal(3.0)),
    ("name", @ast.StrVal("Archer")),
    ("nums", @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0)])),
  ])
  let rw = Ok(
    @evaluator.to_string(@engine.Engine::eval_expr_checked(w, src, ctx)),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  let rv = Ok(
    @evaluator.to_string(@engine.Engine::eval_expr_checked(v, src, ctx)),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  match (rw, rv) {
    (Ok(a), Ok(b)) =>
      if a != b {
        inspect("walk=" + a + " vm=" + b, content="parity")
      }
    (Err(m1), Err(m2)) =>
      if m1 != m2 {
        inspect("walk-err=" + m1 + " vm-err=" + m2, content="parity-err")
      }
    (Ok(a), Err(m)) => inspect("walk ok, vm err " + m, content=a)
    (Err(m), Ok(b)) => inspect("walk err " + m, content=b)
  }
  match rw {
    Ok(s) => s
    Err(m) => "ERR:" + m
  }
}

///|
fn expect_checked(
  src : String,
  expected : String,
  label : String,
) -> Unit raise {
  inspect(checked(src), content=expected)
}

///|
/// Asserts a positioned compile error in expr's FileError layout:
/// "msg (L:C)" then the source line and a caret under column C
/// (dots = col - 1).
fn expect_checked_err(
  src : String,
  msg_line : String,
  dots : Int,
  label : String,
) -> Unit raise {
  let mut caret = ""
  for _ in 0..<dots {
    caret = caret + "."
  }
  let expected = "ERR:" + msg_line + "\n | " + src + "\n | " + caret + "^"
  inspect(checked(src), content=expected)
}

///|
test "checker: valid programs evaluate identically on both engines" {
  expect_checked("1 + 2 * 3", "7", "arith")
  expect_checked("name + \"!\"", "Archer!", "string concat")
  expect_checked("x < 10 && x > 0", "true", "ordering bool")
  expect_checked("let n = 2; nums[:n]", "1,2", "let+slice")
  expect_checked("'r' in name", "true", "in")
}

///|
test "checker: known-type operator mismatches are compile errors" {
  // caret sits on the operator token, as in expr
  expect_checked_err(
    "1 + \"a\"", "invalid operation: + (mismatched types int and string) (1:3)",
    2, "int+string",
  )
  expect_checked_err(
    "\"a\" - 1", "invalid operation: - (mismatched types string and int) (1:5)",
    4, "string-int",
  )
  expect_checked_err(
    "1.5 % 1", "invalid operation: % (mismatched types float and int) (1:5)", 4,
    "float modulo",
  )
  expect_checked_err(
    "1.5 .. 3", "invalid operation: .. (mismatched types float and int) (1:5)", 4,
    "float range",
  )
  expect_checked_err(
    "1 == \"1\"", "invalid operation: == (mismatched types int and string) (1:3)",
    2, "typed eq mismatch",
  )
  expect_checked_err(
    "1 < \"2\"", "invalid operation: < (mismatched types int and string) (1:3)",
    2, "ordering mismatch",
  )
  expect_checked_err(
    "1 && true", "invalid operation: && (mismatched types int and bool) (1:3)", 2,
    "and on int",
  )
}

///|
test "checker: conditions must be bool when statically known" {
  expect_checked_err(
    "if 1 { 2 } else { 3 }", "non-bool expression (type int) used as condition (1:4)",
    3, "if on int",
  )
  expect_checked_err(
    "1 ? 2 : 3", "non-bool expression (type int) used as condition (1:1)", 0, "ternary on int",
  )
  expect_checked("if name { 1 } else { 2 }", "1", "dynamic cond passes compile")
}

///|
test "checker: dynamic sides stay legal (Eval-mode flexibility)" {
  // env values are dynamic: nothing statically wrong
  expect_checked("x + 1", "4", "env int + literal")
  expect_checked("x == \"3\"", "true", "loose env comparison remains")
}

///|
test "checker: let bindings are statically typed in scope" {
  expect_checked_err(
    "let x = 1; x + \"a\"", "invalid operation: + (mismatched types int and string) (1:14)",
    13, "let int then string",
  )
  expect_checked("let x = 1; x * 3", "3", "let int arithmetic")
  expect_checked_err(
    "let s = \"a\"; s + 1", "invalid operation: + (mismatched types string and int) (1:16)",
    15, "let string then int",
  )
  // shadowing replaces the binding's type
  expect_checked("let x = 1; let x = \"s\"; x + \"!\"", "s!", "shadow retypes")
}

///|
test "checker: homogeneous container element natures" {
  expect_checked_err(
    "[1, 2] == [\"a\"]", "invalid operation: == (mismatched types []int and []string) (1:8)",
    7, "array element mismatch",
  )
  expect_checked("[1, 2] == [1, 2]", "true", "same element arrays ok")
  // builtin-argument errors point at the call start (expr parity)
  expect_checked_err(
    "len(5)", "invalid argument for len (type int) (1:1)", 0, "len on int",
  )
  expect_checked_err(
    "int(true)", "invalid argument for int (type bool) (1:1)", 0, "int on bool",
  )
  expect_checked_err(
    "filter(5, # > 0)", "invalid argument for filter (type int) (1:1)", 0, "filter on int",
  )
  expect_checked("upper(\"x\")", "X", "string builtin ok")
}

///|
test "strict mode: unknown top-level names error; Eval mode stays lenient" {
  expect_checked("zz + 1", "ERR:unknown name zz", "unknown name in strict mode")
  // a missing name under eval_expr (Eval mode) is just nil — dynamic
  let inst = @engine.new()
  let r = @engine.Engine::eval_expr(inst, "zz", @ast.ObjectVal([])) catch {
    @engine.EngineErr(m) => abort("eval lenient failed: " + m)
  }
  match r {
    @ast.UndefVal | @ast.NullVal => ()
    other => inspect(@evaluator.to_string(other), content="nil-ish")
  }
}

///|
test "strict mode: piped aggregates and bracket predicates" {
  expect_checked("nums | map(# * 2)", "2,4", "piped map")
  expect_checked("nums | filter(# > 1)", "2", "piped filter")
  expect_checked("nums | map(# * 2) | first()", "2", "piped chain first()")
  expect_checked("[{a:1},{a:2}][.a == 2] | len()", "1", "bracket pred strict")
}

///|
test "strict mode: byte strings type as []uint8" {
  expect_checked("b\"a\" == b\"a\"", "true", "bytes eq compiles")
  expect_checked("len(b\"abc\")", "3", "len of bytes")
  expect_checked("b\"abc\"[0]", "97", "bytes index")
  expect_checked("string(b\"abc\")", "97,98,99", "string of bytes")
  expect_checked("filter(b\"abc\", # > 97)", "98,99", "filter over bytes")
  // compile-mode mismatches mirror expr (Go type name []uint8, caret
  // on the operator)
  expect_checked_err(
    "b\"a\" + b\"b\"", "invalid operation: + (mismatched types []uint8 and []uint8) (1:6)",
    5, "bytes + bytes",
  )
  expect_checked_err(
    "b\"a\" == \"a\"", "invalid operation: == (mismatched types []uint8 and string) (1:6)",
    5, "bytes vs string",
  )
  expect_checked_err(
    "b\"a\" < b\"b\"", "invalid operation: < (mismatched types []uint8 and []uint8) (1:6)",
    5, "bytes ordering",
  )
}
