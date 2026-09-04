// SPDX-License-Identifier: Apache-2.0
// Lexer tests — ported from Jexl's __tests__/lib/Lexer.test.js
// These mirror every test case in the Jest suite to serve as parity oracle.

///|
/// Helper: unwrap Result tokens, aborting on Err.
fn unwrap_tokens(
  r : Result[Array[@lexer.Token], String],
) -> Array[@lexer.Token] {
  match r {
    Ok(toks) => toks
    Err(msg) => abort(msg)
  }
}

///|
/// Helper: assert token type matches expected.
fn expect_typ(t : @lexer.Token, expected : @grammar.TokenType) -> Unit {
  if t.typ != expected {
    abort("token type mismatch")
  }
}

///|
/// Helper: assert token raw matches expected string.
fn expect_raw(t : @lexer.Token, expected : String) -> Unit {
  if t.raw != expected {
    abort("raw mismatch: expected '" + expected + "' got '" + t.raw + "'")
  }
}

///|
test "elements: counts a string as one element" {
  let toks = unwrap_tokens(@lexer.tokenize("\"foo\""))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "\"foo\"")
}

///|
test "elements: supports single-quote strings" {
  let toks = unwrap_tokens(@lexer.tokenize("'foo'"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "'foo'")
}

///|
test "elements: supports escaping double-quotes" {
  let toks = unwrap_tokens(@lexer.tokenize("\"f\\\"oo\""))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "\"f\\\"oo\"")
}

///|
test "elements: supports escaped double-quotes at the end of strings" {
  let toks = unwrap_tokens(@lexer.tokenize("\"foo\\\"\""))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "\"foo\\\"\"")
}

///|
test "elements: supports escaping single-quotes" {
  let toks = unwrap_tokens(@lexer.tokenize("'f\\'oo'"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "'f\\'oo'")
}

///|
test "elements: supports escaped single-quotes at the end of strings" {
  let toks = unwrap_tokens(@lexer.tokenize("'foo\\''"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "'foo\\''")
}

///|
test "elements: counts an identifier as one element" {
  let toks = unwrap_tokens(@lexer.tokenize("alpha12345"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "alpha12345")
}

///|
test "elements: does not split grammar elements out of transforms" {
  let toks = unwrap_tokens(@lexer.tokenize("inString"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "inString")
}

///|
test "elements: allows an identifier to start with and contain $" {
  let toks = unwrap_tokens(@lexer.tokenize("$my$Var"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "$my$Var")
}

///|
test "elements: allows identifiers with accented Latin-1 Supplement letters" {
  let toks = unwrap_tokens(@lexer.tokenize("ÄmyäVarÖö"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "ÄmyäVarÖö")
}

///|
test "elements: allows identifiers with Russian/Cyrillic letters" {
  let toks = unwrap_tokens(@lexer.tokenize("Проверка"))
  assert_eq(toks.length(), 1)
  expect_raw(toks[0], "Проверка")
}

// --- Token tests ---

///|
test "tokens: unquotes string elements" {
  let toks = unwrap_tokens(@lexer.tokenize("\"foo \\\"bar\\\\\""))
  assert_eq(toks.length(), 1)
  expect_typ(toks[0], @grammar.Literal)
  expect_raw(toks[0], "\"foo \\\"bar\\\\\"")
  match toks[0].value {
    Str(s) => assert_eq(s, "foo \"bar\\")
    _ => abort("expected Str value")
  }
}

///|
test "tokens: recognizes booleans" {
  let toks = unwrap_tokens(@lexer.tokenize("true false"))
  assert_eq(toks.length(), 2)
  expect_typ(toks[0], @grammar.Literal)
  expect_raw(toks[0], "true ")
  match toks[0].value {
    Bool(b) => assert_true(b)
    _ => abort("expected Bool(true)")
  }
  expect_typ(toks[1], @grammar.Literal)
  expect_raw(toks[1], "false")
  match toks[1].value {
    Bool(b) => assert_false(b)
    _ => abort("expected Bool(false)")
  }
}

///|
test "tokens: recognizes numerics" {
  let toks = unwrap_tokens(@lexer.tokenize("-7.6 20"))
  assert_eq(toks.length(), 2)
  expect_typ(toks[0], @grammar.Literal)
  match toks[0].value {
    Num(d) => assert_eq(d, -7.6)
    _ => abort("expected Num(-7.6)")
  }
  expect_raw(toks[0], "-7.6 ")
  expect_typ(toks[1], @grammar.Literal)
  match toks[1].value {
    Num(d) => assert_eq(d, 20.0)
    _ => abort("expected Num(20.0)")
  }
  expect_raw(toks[1], "20")
}

///|
test "tokens: recognizes binary operators" {
  let toks = unwrap_tokens(@lexer.tokenize("+"))
  assert_eq(toks.length(), 1)
  expect_typ(toks[0], @grammar.BinaryOp)
  expect_raw(toks[0], "+")
}

///|
test "tokens: recognizes unary operators" {
  let toks = unwrap_tokens(@lexer.tokenize("!"))
  assert_eq(toks.length(), 1)
  expect_typ(toks[0], @grammar.UnaryOp)
  expect_raw(toks[0], "!")
}

///|
test "tokens: recognizes control characters" {
  let toks = unwrap_tokens(@lexer.tokenize("("))
  assert_eq(toks.length(), 1)
  expect_typ(toks[0], @grammar.OpenParen)
  expect_raw(toks[0], "(")
}

///|
test "tokens: recognizes identifiers" {
  let toks = unwrap_tokens(@lexer.tokenize("_foo9_bar"))
  assert_eq(toks.length(), 1)
  expect_typ(toks[0], @grammar.Identifier)
  expect_raw(toks[0], "_foo9_bar")
}

///|
test "tokens: throws on invalid token" {
  match @lexer.tokenize("9foo") {
    Err(_) => ()
    Ok(_) => abort("expected error for invalid token '9foo'")
  }
}

// --- Full expression tokenize ---

///|
test "tokenizes a full expression" {
  let toks = unwrap_tokens(
    @lexer.tokenize("6+x -  -17.55*y<= !foo.bar[\"baz\\\"foz\"]"),
  )
  assert_eq(toks.length(), 15)

  expect_typ(toks[0], @grammar.Literal)
  expect_raw(toks[0], "6")
  match toks[0].value {
    Num(d) => assert_eq(d, 6.0)
    _ => abort("expected Num(6.0)")
  }

  expect_typ(toks[1], @grammar.BinaryOp)
  expect_raw(toks[1], "+")

  expect_typ(toks[2], @grammar.Identifier)
  expect_raw(toks[2], "x ")

  expect_typ(toks[3], @grammar.BinaryOp)
  expect_raw(toks[3], "-  ")

  expect_typ(toks[4], @grammar.Literal)
  expect_raw(toks[4], "-17.55")
  match toks[4].value {
    Num(d) => assert_eq(d, -17.55)
    _ => abort("expected Num(-17.55)")
  }

  expect_typ(toks[5], @grammar.BinaryOp)
  expect_raw(toks[5], "*")

  expect_typ(toks[6], @grammar.Identifier)
  expect_raw(toks[6], "y")

  expect_typ(toks[7], @grammar.BinaryOp)
  expect_raw(toks[7], "<= ")

  expect_typ(toks[8], @grammar.UnaryOp)
  expect_raw(toks[8], "!")

  expect_typ(toks[9], @grammar.Identifier)
  expect_raw(toks[9], "foo")

  expect_typ(toks[10], @grammar.Dot)
  expect_raw(toks[10], ".")

  expect_typ(toks[11], @grammar.Identifier)
  expect_raw(toks[11], "bar")

  expect_typ(toks[12], @grammar.OpenBracket)
  expect_raw(toks[12], "[")

  expect_typ(toks[13], @grammar.Literal)
  expect_raw(toks[13], "\"baz\\\"foz\"")
  match toks[13].value {
    Str(s) => assert_eq(s, "baz\"foz")
    _ => abort("expected Str value")
  }

  expect_typ(toks[14], @grammar.CloseBracket)
  expect_raw(toks[14], "]")
}

///|
test "considers minus to be negative appropriately" {
  let toks = unwrap_tokens(@lexer.tokenize("-1?-2:-3"))
  assert_eq(toks.length(), 5)

  expect_typ(toks[0], @grammar.Literal)
  expect_raw(toks[0], "-1")
  match toks[0].value {
    Num(d) => assert_eq(d, -1.0)
    _ => abort("expected Num(-1.0)")
  }

  expect_typ(toks[1], @grammar.Question)
  expect_raw(toks[1], "?")

  expect_typ(toks[2], @grammar.Literal)
  expect_raw(toks[2], "-2")
  match toks[2].value {
    Num(d) => assert_eq(d, -2.0)
    _ => abort("expected Num(-2.0)")
  }

  expect_typ(toks[3], @grammar.Colon)
  expect_raw(toks[3], ":")

  expect_typ(toks[4], @grammar.Literal)
  expect_raw(toks[4], "-3")
  match toks[4].value {
    Num(d) => assert_eq(d, -3.0)
    _ => abort("expected Num(-3.0)")
  }
}
