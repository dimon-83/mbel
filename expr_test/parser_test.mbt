// SPDX-License-Identifier: Apache-2.0
// expr front-end parser tests — structure assertions via dump().
// Cases mirror expr's parser_test.go focus areas for the new syntax.

///|
fn dump_of(src : String) -> String raise @expr.ParseErrorExpr {
  @expr.dump(@expr.parse(src))
}

///|
fn expect_dump(src : String, expected : String, label : String) -> Unit raise {
  let d = dump_of(src) catch {
    ParseErrExpr(msg, l, c) => {
      // expectations starting with "parse error at" accept any parse
      // error; anything else must match the message exactly
      if expected.length() >= 14 && expected[:14] == "parse error at" {
        return
      }
      inspect(
        "parse error at " + l.to_string() + ":" + c.to_string() + ": " + msg,
        content=expected,
      )
      return
    }
  }
  inspect(d, content=expected)
}

///|
test "expr parser: literal family" {
  expect_dump("42", "int:42", "int")
  expect_dump("0x2A", "int:42", "hex")
  expect_dump("0b101", "int:5", "binary")
  expect_dump("0o17", "int:15", "octal")
  expect_dump("10_000", "int:10000", "underscore")
  expect_dump(".5", "float:0.5", "leading dot")
  expect_dump("1.5e-3", "float:0.0015", "exponent")
  expect_dump("'hi'", "str:hi", "string")
  expect_dump("`raw\\n`", "str:raw\\n", "raw string keeps backslash")
  expect_dump("nil", "nil", "nil")
}

///|
test "expr parser: precedence and associativity" {
  expect_dump("1 + 2 * 3", "bin(+,int:1,bin(*,int:2,int:3))", "mul binds")
  expect_dump(
    "2 ** 3 ** 2", "bin(**,int:2,bin(**,int:3,int:2))", "power right-assoc",
  )
  expect_dump(
    "1 + 2 ?? 3", "bin(+,int:1,bin(??,int:2,int:3))", "?? lowest (mbel v1: ?? tree under +; expr would error on mix)",
  )
  expect_dump(
    "a ?? b ?? c", "bin(??,bin(??,id:a,id:b),id:c)", "?? left-assoc (expr parity)",
  )
  expect_dump("1 < 2 == true", "bin(==,bin(<,int:1,int:2),true)", "cmp then eq")
  expect_dump("1..3", "bin(..,int:1,int:3)", "range")
  expect_dump("a and b or c", "bin(or,bin(and,id:a,id:b),id:c)", "and>or")
}

///|
test "expr parser: chained comparisons" {
  expect_dump(
    "1 < x < 10", "bin(and,bin(<,int:1,id:x),bin(<,id:x,int:10))", "chain",
  )
  expect_dump(
    "1 < x <= 5 < y", "bin(and,bin(and,bin(<,int:1,id:x),bin(<=,id:x,int:5)),bin(<,int:5,id:y))",
    "chain 3 (each link compares the last operand — expr semantics)",
  )
}

///|
test "expr parser: not-suffixed operators" {
  expect_dump(
    "a not in [1,2]", "un(not,bin(in,id:a,arr[int:1,int:2]))", "not in",
  )
  expect_dump(
    "a not matches \"x\"", "un(not,bin(matches,id:a,str:x))", "not matches",
  )
}

///|
test "expr parser: members, calls, optional chain, slice" {
  expect_dump("foo.bar", "member(id:foo.bar)", "member")
  expect_dump("foo?.bar", "member(id:foo.bar?)", "optional member")
  expect_dump("foo?.[0]", "index(id:foo,int:0)", "optional index")
  expect_dump("foo[1:3]", "slice(id:foo,int:1,int:3)", "slice")
  expect_dump("foo[:2]", "slice(id:foo,?,int:2)", "slice open from")
  expect_dump("foo[1:]", "slice(id:foo,int:1,?)", "slice open to")
  expect_dump("f(1, 2)", "call(id:f,int:1,int:2)", "call")
  expect_dump("obj.m(3)", "call(member(id:obj.m),int:3)", "method call")
}

///|
test "expr parser: map, array, pipe" {
  expect_dump("{a: 1, 'b': 2}", "map{id:a:int:1,str:b:int:2}", "map keys")
  expect_dump("[1, [2, 3]]", "arr[int:1,arr[int:2,int:3]]", "nested array")
  expect_dump(
    "x | upper() | trim()", "call(id:trim,call(id:upper,id:x))", "pipe desugar",
  )
}

///|
test "expr parser: if-else, let, sequence, ternary" {
  expect_dump("if a { 1 } else { 2 }", "cond(id:a,int:1,int:2)", "if else")
  expect_dump(
    "if a { 1 } else if b { 2 } else { 3 }", "cond(id:a,int:1,cond(id:b,int:2,int:3))",
    "else if",
  )
  expect_dump("let x = 42; x + 1", "let(x,int:42,bin(+,id:x,int:1))", "let")
  expect_dump(
    "let x = 1; let y = 2; x + y", "let(x,int:1,let(y,int:2,bin(+,id:x,id:y)))",
    "let chain",
  )
  expect_dump(
    "let x = 1; x + 1; x * 2", "let(x,int:1,seq[bin(+,id:x,int:1);bin(*,id:x,int:2)])",
    "sequence",
  )
  expect_dump("a ? b : c", "cond(id:a,id:b,id:c)", "ternary")
  expect_dump("a ?: b", "cond(id:a,?,id:b)", "elvis")
}

///|
test "expr parser: predicates and pointers" {
  expect_dump(
    "filter(xs, {# % 2 == 0})", "call(id:filter,id:xs,pred(bin(==,bin(%,ptr:#,int:2),int:0)))",
    "brace pred",
  )
  expect_dump(
    "map(xs, #index)", "call(id:map,id:xs,ptr:#index)", "bare pointer",
  )
  expect_dump(
    "filter(users, .age >= 18)", "call(id:filter,id:users,bin(>=,member(ptr:#.age),int:18))",
    "relative field",
  )
  expect_dump(
    "reduce(xs, #acc + #)", "call(id:reduce,id:xs,bin(+,ptr:#acc,ptr:#))", "reduce pred",
  )
}

///|
test "expr parser: unary vs power precedence (expr parity)" {
  expect_dump("-2 ** 2", "un(-,bin(**,int:2,int:2))", "-x**y = -(x**y)")
  expect_dump("2 ** -2", "bin(**,int:2,un(-,int:2))", "negative exponent")
  expect_dump("-2 * 3", "bin(*,un(-,int:2),int:3)", "- binds tighter than *")
  expect_dump("!x == y", "bin(==,un(!,id:x),id:y)", "! then ==")
  expect_dump("not x and y", "bin(and,un(not,id:x),id:y)", "not then and")
}

///|
test "expr parser: ?? mixing rules" {
  // `1 + 2 ?? 3` is legal: ?? (prec 500) binds tighter than +.
  expect_dump("1 + 2 ?? 3", "bin(+,int:1,bin(??,int:2,int:3))", "?? inside +")
  expect_dump("a ?? b ?? c", "bin(??,bin(??,id:a,id:b),id:c)", "?? chains")
  // an operator directly after `??` at the same level is an error
  expect_dump("1 ?? 2 + 3", "parse error at", "?? then + rejected")
  expect_dump("foo ?? bar || baz", "parse error at", "?? then || rejected")
  expect_dump(
    "(1 ?? 2) + 3", "bin(+,bin(??,int:1,int:2),int:3)", "parens reset",
  )
}

///|
test "expr parser: if/else requires else and full block bodies" {
  expect_dump("if a { 1 } else { 2 }", "cond(id:a,int:1,int:2)", "if else")
  expect_dump(
    "if a { 1; 2 } else { 3 }", "cond(id:a,seq[int:1;int:2],int:3)", "sequence branch",
  )
  expect_dump(
    "if a { let x = 1; x } else { 2 }", "cond(id:a,let(x,int:1,id:x),int:2)", "let inside branch",
  )
  expect_dump(
    "if a { 1 } else if b { 2 } else { 3 }", "cond(id:a,int:1,cond(id:b,int:2,int:3))",
    "else if",
  )
  expect_dump("if a { 1 }", "parse error at", "missing else rejected")
  expect_dump(
    "1 + if a { 1 } else { 2 }", "parse error at", "if not allowed mid-expression",
  )
  expect_dump(
    "(if a { 1 } else { 2 }) + 3", "bin(+,cond(id:a,int:1,int:2),int:3)", "parenthesized if is a value",
  )
}

///|
test "expr parser: let at precedence-0 sites only" {
  expect_dump(
    "(let x = 1; x) + 2", "bin(+,let(x,int:1,id:x),int:2)", "let in parens",
  )
  expect_dump("let $env = 1; 2", "parse error at", "cannot declare $env")
  expect_dump("1 | 2", "parse error at", "pipe rhs must be a call")
}

///|
test "expr parser: not-suffixed string operators" {
  expect_dump(
    "a not contains \"x\"", "un(not,bin(contains,id:a,str:x))", "not contains",
  )
  expect_dump(
    "a startsWith \"x\"", "bin(startsWith,id:a,str:x)", "startsWith op",
  )
  expect_dump("a endsWith \"x\"", "bin(endsWith,id:a,str:x)", "endsWith op")
}

///|
test "expr parser: comments and escapes" {
  expect_dump("1 + /* c */ 2", "bin(+,int:1,int:2)", "block comment")
  expect_dump("1 // x\n+ 2", "bin(+,int:1,int:2)", "line comment")
  expect_dump("\"a\\n\\u{41}b\"", "str:a\nAb", "escapes")
}
