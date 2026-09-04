// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// parser_test: blackbox tests for the parser package.
// Ported from Jexl's __tests__/lib/parser/Parser.test.js — the expected
// AST shapes mirror the JS `toEqual` expectations verbatim.

///|
/// Parses an expression string into an AST, aborting on tokenize/parse
/// errors so test failures surface the underlying cause.
fn expect_ast(expr : String, expected : @ast.AstNode) -> Unit {
  let toks = match @lexer.tokenize(expr) {
    Ok(t) => t
    Err(m) => abort("tokenize failed for '" + expr + "': " + m)
  }
  let tree = @parser.parse(toks) catch {
    _ => abort("parse failed for '" + expr + "'")
  }
  match tree {
    Some(node) =>
      if !@ast.ast_equal(node, expected) {
        abort("AST mismatch for '" + expr + "'")
      }
    None => abort("empty parse for '" + expr + "'")
  }
}

// --- Expected-node builders (mirroring JS object literals) ---

///|
fn lit_num(d : Double) -> @ast.AstNode {
  @ast.literal(@ast.NumVal(d))
}

///|
fn lit_str(s : String) -> @ast.AstNode {
  @ast.literal(@ast.StrVal(s))
}

///|
fn lit_bool(b : Bool) -> @ast.AstNode {
  @ast.literal(@ast.BoolVal(b))
}

///|
fn ident(name : String) -> @ast.AstNode {
  @ast.identifier(name)
}

///|
fn ident_from(name : String, from : @ast.AstNode) -> @ast.AstNode {
  let n = @ast.identifier(name)
  n.from = Some(from)
  n
}

///|
fn ident_rel(name : String) -> @ast.AstNode {
  let n = @ast.identifier(name)
  n.relative = true
  n
}

///|
fn bin(op : String, left : @ast.AstNode, right : @ast.AstNode) -> @ast.AstNode {
  let n = @ast.binary_expr(op, left)
  n.right = Some(right)
  n
}

///|
fn un(op : String, right : @ast.AstNode) -> @ast.AstNode {
  let n = @ast.unary_expr(op)
  n.right = Some(right)
  n
}

///|
fn ternary(
  test_expr : @ast.AstNode,
  consequent : @ast.AstNode?,
  alternate : @ast.AstNode?,
) -> @ast.AstNode {
  let n = @ast.conditional()
  n.cond_test = Some(test_expr)
  n.consequent = consequent
  n.alternate = alternate
  n
}

///|
fn arrlit(items : Array[@ast.AstNode]) -> @ast.AstNode {
  let n = @ast.array_literal()
  n.array_value = items
  n
}

///|
fn objlit(pairs : Array[(String, @ast.AstNode)]) -> @ast.AstNode {
  let n = @ast.object_literal()
  n.obj_value = pairs
  n
}

///|
fn flt(
  expr : @ast.AstNode,
  relative : Bool,
  subject : @ast.AstNode,
) -> @ast.AstNode {
  let n = @ast.filter_expression(expr, relative, subject)
  n
}

///|
fn fc(name : String, pool : String, args : Array[@ast.AstNode]) -> @ast.AstNode {
  let n = @ast.function_call(name, pool)
  n.args = args
  n
}

// --- Tests (mirroring Parser.test.js) ---

///|
test "constructs an AST for 1+2" {
  expect_ast("1+2", bin("+", lit_num(1.0), lit_num(2.0)))
}

///|
test "adds heavier operations to the right for 2+3*4" {
  expect_ast(
    "2+3*4",
    bin("+", lit_num(2.0), bin("*", lit_num(3.0), lit_num(4.0))),
  )
}

///|
test "encapsulates for lighter operation in 2*3+4" {
  expect_ast(
    "2*3+4",
    bin("+", bin("*", lit_num(2.0), lit_num(3.0)), lit_num(4.0)),
  )
}

///|
test "handles encapsulation of subtree in 2+3*4==5/6-7" {
  expect_ast(
    "2+3*4==5/6-7",
    bin(
      "==",
      bin("+", lit_num(2.0), bin("*", lit_num(3.0), lit_num(4.0))),
      bin("-", bin("/", lit_num(5.0), lit_num(6.0)), lit_num(7.0)),
    ),
  )
}

///|
test "handles a unary operator" {
  expect_ast(
    "1*!!true-2",
    bin(
      "-",
      bin("*", lit_num(1.0), un("!", un("!", lit_bool(true)))),
      lit_num(2.0),
    ),
  )
}

///|
test "handles a subexpression" {
  expect_ast(
    "(2+3)*4",
    bin("*", bin("+", lit_num(2.0), lit_num(3.0)), lit_num(4.0)),
  )
}

///|
test "handles nested subexpressions" {
  expect_ast(
    "(4*(2+3))/5",
    bin(
      "/",
      bin("*", lit_num(4.0), bin("+", lit_num(2.0), lit_num(3.0))),
      lit_num(5.0),
    ),
  )
}

///|
test "handles object literals" {
  expect_ast(
    "{foo: \"bar\", tek: 1+2}",
    objlit([
      ("foo", lit_str("bar")),
      ("tek", bin("+", lit_num(1.0), lit_num(2.0))),
    ]),
  )
}

///|
test "handles dashes in key" {
  expect_ast(
    "{'with-dash': \"bar\", tek: 1+2}",
    objlit([
      ("with-dash", lit_str("bar")),
      ("tek", bin("+", lit_num(1.0), lit_num(2.0))),
    ]),
  )
}

///|
test "handles nested object literals" {
  expect_ast(
    "{foo: {bar: \"tek\"}}",
    objlit([("foo", objlit([("bar", lit_str("tek"))]))]),
  )
}

///|
test "handles empty object literals" {
  expect_ast("{}", objlit([]))
}

///|
test "handles array literals" {
  expect_ast(
    "[\"foo\", 1+2]",
    arrlit([lit_str("foo"), bin("+", lit_num(1.0), lit_num(2.0))]),
  )
}

///|
test "handles nested array literals" {
  expect_ast(
    "[\"foo\", [\"bar\", \"tek\"]]",
    arrlit([lit_str("foo"), arrlit([lit_str("bar"), lit_str("tek")])]),
  )
}

///|
test "handles empty array literals" {
  expect_ast("[]", arrlit([]))
}

///|
test "chains traversed identifiers" {
  expect_ast(
    "foo.bar.baz + 1",
    bin("+", ident_from("baz", ident_from("bar", ident("foo"))), lit_num(1.0)),
  )
}

///|
test "applies transforms and arguments" {
  expect_ast(
    "foo|tr1|tr2.baz|tr3({bar:\"tek\"})",
    fc("tr3", "transforms", [
      ident_from(
        "baz",
        fc("tr2", "transforms", [fc("tr1", "transforms", [ident("foo")])]),
      ),
      objlit([("bar", lit_str("tek"))]),
    ]),
  )
}

///|
test "handles multiple arguments in transforms" {
  expect_ast(
    "foo|bar(\"tek\", 5, true)",
    fc("bar", "transforms", [
      ident("foo"),
      lit_str("tek"),
      lit_num(5.0),
      lit_bool(true),
    ]),
  )
}

///|
test "applies filters to identifiers" {
  expect_ast(
    "foo[1][.bar[0]==\"tek\"].baz",
    ident_from(
      "baz",
      flt(
        bin("==", flt(lit_num(0.0), false, ident_rel("bar")), lit_str("tek")),
        true,
        flt(lit_num(1.0), false, ident("foo")),
      ),
    ),
  )
}

///|
test "allows mixing relative and non-relative identifiers" {
  expect_ast(
    "foo[.bar.baz == tek]",
    flt(
      bin("==", ident_from("baz", ident_rel("bar")), ident("tek")),
      true,
      ident("foo"),
    ),
  )
}

///|
test "allows mixing relative and non-relative identifiers in a complex case" {
  expect_ast(
    "foo.bar[.baz == tek.tak]",
    flt(
      bin("==", ident_rel("baz"), ident_from("tak", ident("tek"))),
      true,
      ident_from("bar", ident("foo")),
    ),
  )
}

///|
test "allows dot notation for all operands" {
  expect_ast(
    "\"foo\".length + {foo: \"bar\"}.foo",
    bin(
      "+",
      ident_from("length", lit_str("foo")),
      ident_from("foo", objlit([("foo", lit_str("bar"))])),
    ),
  )
}

///|
test "allows dot notation on subexpressions" {
  expect_ast(
    "(\"foo\" + \"bar\").length",
    ident_from("length", bin("+", lit_str("foo"), lit_str("bar"))),
  )
}

///|
test "allows dot notation on arrays" {
  expect_ast(
    "[\"foo\", \"bar\"].length",
    ident_from("length", arrlit([lit_str("foo"), lit_str("bar")])),
  )
}

///|
test "handles a ternary expression" {
  expect_ast(
    "foo ? 1 : 0",
    ternary(ident("foo"), Some(lit_num(1.0)), Some(lit_num(0.0))),
  )
}

///|
test "handles nested and grouped ternary expressions" {
  expect_ast(
    "foo ? (bar ? 1 : 2) : 3",
    ternary(
      ident("foo"),
      Some(ternary(ident("bar"), Some(lit_num(1.0)), Some(lit_num(2.0)))),
      Some(lit_num(3.0)),
    ),
  )
}

///|
test "handles nested, non-grouped ternary expressions" {
  expect_ast(
    "foo ? bar ? 1 : 2 : 3",
    ternary(
      ident("foo"),
      Some(ternary(ident("bar"), Some(lit_num(1.0)), Some(lit_num(2.0)))),
      Some(lit_num(3.0)),
    ),
  )
}

///|
test "handles ternary expression with objects" {
  expect_ast(
    "foo ? {bar: \"tek\"} : \"baz\"",
    ternary(
      ident("foo"),
      Some(objlit([("bar", lit_str("tek"))])),
      Some(lit_str("baz")),
    ),
  )
}

///|
test "balances a binary op between complex identifiers" {
  expect_ast(
    "a.b == c.d",
    bin("==", ident_from("b", ident("a")), ident_from("d", ident("c"))),
  )
}

///|
test "handles whitespace in an expression" {
  expect_ast("\t2\r\n+\n\r3\n\n", bin("+", lit_num(2.0), lit_num(3.0)))
}
