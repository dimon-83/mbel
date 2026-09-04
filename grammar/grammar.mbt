// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// grammar package: token types and element classification
//
// Ported from Jexl's lib/grammar.js element type definitions.
// The Lexer uses these to classify tokens; the Parser/Evaluator
// will add precedence and eval semantics in a later phase.

///|
/// Token type classification for expression elements.
///
/// Mirrors Jexl's token types: `literal`, `identifier`, `binaryOp`,
/// `unaryOp`, plus control-character types named in the grammar.
pub(all) enum TokenType {
  Literal
  Identifier
  BinaryOp
  UnaryOp
  Dot
  OpenBracket
  CloseBracket
  Pipe
  OpenCurl
  CloseCurl
  Colon
  Comma
  OpenParen
  CloseParen
  Question
} derive(Debug, Eq)

///|
/// Returns the token type for a default-grammar element string.
///
/// Returns `None` if the string is not a grammar element (i.e. it's
/// a literal, identifier, or invalid).
pub fn element_type(s : String) -> TokenType? {
  match s {
    "+"
    | "-"
    | "*"
    | "/"
    | "//"
    | "%"
    | "^"
    | "=="
    | "!="
    | ">"
    | ">="
    | "<"
    | "<="
    | "&&"
    | "||"
    | "in" => Some(BinaryOp)
    "!" => Some(UnaryOp)
    "." => Some(Dot)
    "[" => Some(OpenBracket)
    "]" => Some(CloseBracket)
    "|" => Some(Pipe)
    "{" => Some(OpenCurl)
    "}" => Some(CloseCurl)
    ":" => Some(Colon)
    "," => Some(Comma)
    "(" => Some(OpenParen)
    ")" => Some(CloseParen)
    "?" => Some(Question)
    _ => None
  }
}

///|
/// Returns the precedence of a binary operator.
/// Higher number = binds tighter. Non-operators return 0.
/// Values from Jexl's grammar.js. `!` (unary) has Infinity there;
/// the parser walks through unary nodes when placing binary ops, so
/// it must outrank every finite precedence.
pub fn precedence(op : String) -> Int {
  match op {
    "!" => 1000000
    "^" | "%" => 50
    "*" | "/" | "//" => 40
    "+" | "-" => 30
    "==" | "!=" | ">" | ">=" | "<" | "<=" | "in" => 20
    "&&" | "||" => 10
    _ => 0
  }
}

///|
/// Token types after which a `-` should be interpreted as negation
/// rather than subtraction.  Mirrors Jexl's `minusNegatesAfter`.
pub fn minus_negates_after(t : TokenType) -> Bool {
  match t {
    BinaryOp
    | UnaryOp
    | OpenParen
    | OpenBracket
    | Question
    | Colon
    | Comma
    | Pipe
    | OpenCurl => true
    _ => false
  }
}
