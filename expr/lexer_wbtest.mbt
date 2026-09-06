// SPDX-License-Identifier: Apache-2.0
// Whitebox lexer tests: token texts carry decoded string/byte content,
// which the blackbox parser dumps cannot show.

///|
fn lex_first(src : String) -> String raise LexError {
  // text of all non-EOF tokens concatenated
  let toks = tokenize(src)
  let out = StringBuilder::new()
  for t in toks {
    if t.kind is TkEOF {
      break
    }
    out.write_string(t.text)
  }
  out.to_string()
}

///|
fn expect_tok(src : String, expected : String, label : String) -> Unit raise {
  let got = lex_first(src) catch {
    LexErr(msg, line, col) => {
      inspect(
        "lex error at " + line.to_string() + ":" + col.to_string() + ": " + msg,
        content=expected,
      )
      return
    }
  }
  inspect(got, content=expected)
}

///|
fn expect_tok_err(src : String, label : String) -> Unit raise {
  let got = lex_first(src) catch {
    LexErr(_, _, _) => return // lex error is the expected outcome
  }
  inspect(got, content="lex error expected: " + label)
}

///|
test "lexer wb: quoted string escapes" {
  expect_tok("\"\\101\"", "A", "octal")
  expect_tok("'\\x41'", "A", "hex in single quotes")
  expect_tok("\"\\u0041\"", "A", "uXXXX")
  expect_tok("\"\\U00000041\"", "A", "UXXXXXXXX")
  expect_tok("\"\\u{1F600}\"", "\u{1F600}", "u{} astral")
  expect_tok("\"\\0\"", "\u{0}", "NUL")
  expect_tok("\"a\\nb\"", "a\nb", "newline escape")
  expect_tok_err("\"\\q\"", "invalid escape")
  expect_tok_err("\"\\777\"", "octal overflow")
  expect_tok_err("\"\\u{110000}\"", "code point overflow")
  expect_tok_err("\"a\nb\"", "raw newline rejected")
}

///|
test "lexer wb: raw backtick strings keep escapes, double backtick" {
  expect_tok("`a\\nb`", "a\\nb", "raw keeps backslash")
  expect_tok("`a``b`", "a`b", "doubled backtick")
  expect_tok("`a\nb`", "a\nb", "raw newline allowed")
}

///|
test "lexer wb: byte strings carry decoded bytes" {
  expect_tok("b\"\\x41\\nA\"", "A\nA", "byte escapes")
  expect_tok("b\"\\101\"", "A", "byte octal")
  expect_tok("b\"\\377\"", "\u{FF}", "byte max octal")
  expect_tok_err("b\"\\400\"", "byte octal overflow")
  expect_tok_err("b\"\\u0041\"", "no \\u in byte strings")
  expect_tok("b\"hi\"", "hi", "plain bytes")
  expect_tok("B'hi'", "hi", "uppercase B single quotes")
  // non-ASCII is UTF-8-encoded: ÿ -> 0xC3 0xBF
  expect_tok("b\"ÿ\"", "\u{C3}\u{BF}", "utf8 bytes of non-ascii char")
}
