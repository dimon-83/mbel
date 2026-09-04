// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// evaluator_test: blackbox tests for the evaluator package.
// Ported from Jexl's __tests__/lib/evaluator/Evaluator.test.js.

///|
/// Value builders for contexts and expected results.
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
/// Tokenizes, parses, evaluates, and compares the result to `expected`.
fn expect_eval(
  expr : String,
  context : @ast.Value,
  expected : @ast.Value,
) -> Unit {
  let grammar = @evaluator.default_grammar()
  let toks = match @lexer.tokenize(expr) {
    Ok(t) => t
    Err(m) => abort("tokenize failed for '" + expr + "': " + m)
  }
  let tree = @parser.parse(toks) catch {
    _ => abort("parse failed for '" + expr + "'")
  }
  let node = match tree {
    Some(n) => n
    None => abort("empty parse for '" + expr + "'")
  }
  let e = @evaluator.new_evaluator(grammar, context)
  let result = e.eval(node) catch {
    _ => abort("eval failed for '" + expr + "'")
  }
  if !@ast.value_equal(result, expected) {
    abort("eval mismatch for '" + expr + "'")
  }
}

///|
fn unwrap_toks(expr : String) -> Array[@lexer.Token] {
  match @lexer.tokenize(expr) {
    Ok(t) => t
    Err(m) => abort(m)
  }
}

///|
test "evaluates synchronously (PromiseSync equivalent)" {
  expect_eval("2 + 2", v_obj([]), v_num(4.0))
}

///|
test "evaluates an arithmetic expression" {
  expect_eval("(2 + 3) * 4", v_obj([]), v_num(20.0))
}

///|
test "evaluates a string concat" {
  expect_eval(
    "\"Hello\" + (4+4) + \"Wo\\\"rld\"",
    v_obj([]),
    v_str("Hello8Wo\"rld"),
  )
}

///|
test "evaluates a true comparison expression" {
  expect_eval("2 > 1", v_obj([]), v_bool(true))
}

///|
test "evaluates a false comparison expression" {
  expect_eval("2 <= 1", v_obj([]), v_bool(false))
}

///|
test "evaluates a complex expression" {
  expect_eval("\"foo\" && 6 >= 6 && 0 + 1 && true", v_obj([]), v_bool(true))
}

///|
test "evaluates an identifier chain" {
  let context = v_obj([
    ("foo", v_obj([("baz", v_obj([("bar", v_str("tek"))]))])),
  ])
  expect_eval("foo.baz.bar", context, v_str("tek"))
}

///|
test "applies transforms" {
  let grammar = @evaluator.default_grammar()
  grammar.transforms.push(
    (
      "half",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        v_num(@evaluator.to_number(args[0]) / 2.0)
      },
    ),
  )
  let toks = unwrap_toks("foo|half + 3")
  let tree = @parser.parse(toks) catch { _ => abort("parse failed") }
  let e = @evaluator.new_evaluator(grammar, v_obj([("foo", v_num(10.0))]))
  let result = e.eval(tree.unwrap()) catch { _ => abort("eval failed") }
  assert_true(@ast.value_equal(result, v_num(8.0)))
}

///|
test "filters arrays" {
  let context = v_obj([
    (
      "foo",
      v_obj([
        (
          "bar",
          v_arr([
            v_obj([("tek", v_str("hello"))]),
            v_obj([("tek", v_str("baz"))]),
            v_obj([("tok", v_str("baz"))]),
          ]),
        ),
      ]),
    ),
  ])
  expect_eval(
    "foo.bar[.tek == \"baz\"]",
    context,
    v_arr([v_obj([("tek", v_str("baz"))])]),
  )
}

///|
test "assumes array index 0 when traversing" {
  let context = v_obj([
    (
      "foo",
      v_obj([
        (
          "bar",
          v_arr([
            v_obj([("tek", v_obj([("hello", v_str("world"))]))]),
            v_obj([("tek", v_obj([("hello", v_str("universe"))]))]),
          ]),
        ),
      ]),
    ),
  ])
  expect_eval("foo.bar.tek.hello", context, v_str("world"))
}

///|
test "makes array elements addressable by index" {
  let context = v_obj([
    (
      "foo",
      v_obj([
        (
          "bar",
          v_arr([
            v_obj([("tek", v_str("tok"))]),
            v_obj([("tek", v_str("baz"))]),
            v_obj([("tek", v_str("foz"))]),
          ]),
        ),
      ]),
    ),
  ])
  expect_eval("foo.bar[1].tek", context, v_str("baz"))
}

///|
test "allows filters to select object properties" {
  let context = v_obj([
    ("foo", v_obj([("baz", v_obj([("bar", v_str("tek"))]))])),
  ])
  expect_eval("foo[\"ba\" + \"z\"].bar", context, v_str("tek"))
}

///|
test "throws when transform does not exist" {
  let toks = unwrap_toks("\"hello\"|world")
  let tree = @parser.parse(toks) catch { _ => abort("parse failed") }
  let e = @evaluator.new_evaluator(@evaluator.default_grammar(), v_obj([]))
  try {
    ignore(e.eval(tree.unwrap()))
    abort("expected EvalError")
  } catch {
    @evaluator.EvalErr(msg) => assert_true(msg.contains("world"))
  }
}

///|
test "applies the DivFloor operator" {
  expect_eval("7 // 2", v_obj([]), v_num(3.0))
}

///|
test "evaluates an object literal" {
  expect_eval(
    "{foo: {bar: \"tek\"}}",
    v_obj([]),
    v_obj([("foo", v_obj([("bar", v_str("tek"))]))]),
  )
}

///|
test "evaluates an empty object literal" {
  expect_eval("{}", v_obj([]), v_obj([]))
}

///|
test "evaluates a transform with multiple args" {
  let grammar = @evaluator.default_grammar()
  grammar.transforms.push(
    (
      "concat",
      fn(args : Array[@ast.Value]) -> @ast.Value {
        v_str(
          @evaluator.to_string(args[0]) +
          ": " +
          @evaluator.to_string(args[1]) +
          @evaluator.to_string(args[2]) +
          @evaluator.to_string(args[3]),
        )
      },
    ),
  )
  let toks = unwrap_toks("\"foo\"|concat(\"baz\", \"bar\", \"tek\")")
  let tree = @parser.parse(toks) catch { _ => abort("parse failed") }
  let e = @evaluator.new_evaluator(grammar, v_obj([]))
  let result = e.eval(tree.unwrap()) catch { _ => abort("eval failed") }
  assert_true(@ast.value_equal(result, v_str("foo: bazbartek")))
}

///|
test "evaluates dot notation for object literals" {
  expect_eval("{foo: \"bar\"}.foo", v_obj([]), v_str("bar"))
}

///|
test "allows access to literal properties" {
  expect_eval("\"foo\".length", v_obj([]), v_num(3.0))
}

///|
test "evaluates array literals" {
  expect_eval("[\"foo\", 1+2]", v_obj([]), v_arr([v_str("foo"), v_num(3.0)]))
}

///|
test "applies the in operator to strings" {
  expect_eval("\"bar\" in \"foobartek\"", v_obj([]), v_bool(true))
  expect_eval("\"baz\" in \"foobartek\"", v_obj([]), v_bool(false))
}

///|
test "applies the in operator to arrays" {
  expect_eval("\"bar\" in [\"foo\",\"bar\",\"tek\"]", v_obj([]), v_bool(true))
  expect_eval("\"baz\" in [\"foo\",\"bar\",\"tek\"]", v_obj([]), v_bool(false))
}

///|
test "evaluates a conditional expression" {
  expect_eval("\"foo\" ? 1 : 2", v_obj([]), v_num(1.0))
  expect_eval("\"\" ? 1 : 2", v_obj([]), v_num(2.0))
}

///|
test "allows missing consequent in ternary" {
  expect_eval("\"foo\" ?: \"bar\"", v_obj([]), v_str("foo"))
}

///|
test "does not treat falsey properties as undefined" {
  expect_eval("\"\".length", v_obj([]), v_num(0.0))
}

///|
test "returns empty array when applying a filter to an undefined value" {
  let context = v_obj([("a", v_obj([])), ("d", v_num(4.0))])
  let toks = unwrap_toks("a.b[.c == d]")
  let tree = @parser.parse(toks) catch { _ => abort("parse failed") }
  let e = @evaluator.new_evaluator(@evaluator.default_grammar(), context)
  let result = e.eval(tree.unwrap()) catch { _ => abort("eval failed") }
  match result {
    @ast.ArrayVal(xs) => assert_eq(xs.length(), 0)
    _ => abort("expected array result")
  }
}

///|
test "evaluates an expression with arbitrary whitespace" {
  expect_eval("(\t2\n+\n3) *\n4\n\r\n", v_obj([]), v_num(20.0))
}

///|
test "evaluates an expression with $ in identifiers" {
  let context = v_obj([
    ("$", v_num(5.0)),
    ("$foo", v_num(6.0)),
    ("$foo$bar", v_num(7.0)),
    ("$bar", v_num(8.0)),
  ])
  expect_eval("$+$foo+$foo$bar+$bar", context, v_num(26.0))
}
