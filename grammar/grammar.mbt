// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// grammar package: token types and element definitions
//
// Ported from Jexl's lib/grammar.js element type definitions plus the
// Lexer/Parser-visible parts of the grammar object. The Lexer matches
// element symbols (longest first, word boundaries for identifier-like
// symbols), the Parser reads operator precedence from them, and the
// Evaluator carries the eval functions in its op tables.

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
  Pointer
} derive(Debug, Eq)

///|
/// A grammar element definition: a symbol plus its token type and
/// operator precedence. Mirrors one entry of Jexl's
/// `grammar.elements` map (type + precedence; eval functions live in
/// the evaluator's op tables).
pub struct ElementDef {
  symbol : String
  elem_type : TokenType
  precedence : Int
}

///|
/// Whether an element symbol is identifier-like: when true the Lexer
/// only matches it at word boundaries, exactly like Jexl's
/// `_escapeRegExp`, which wraps elements matching the identifier
/// regex in `\b...\b` (e.g. `in` splits `a in b` but not `inString`).
pub fn is_ident_like(symbol : String) -> Bool {
  let chars = symbol.to_array()
  let n = chars.length()
  if n == 0 || !is_ident_start_c(chars[0]) {
    return false
  }
  for i in 1..<n {
    if !is_ident_cont_c(chars[i]) {
      return false
    }
  }
  true
}

///|
fn is_ident_start_c(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c == '$' ||
  (c >= '\u00C0' && c <= '\u00D6') ||
  (c >= '\u00D8' && c <= '\u00F6') ||
  (c >= '\u00F8' && c <= '\u00FF')
}

///|
fn is_ident_cont_c(c : Char) -> Bool {
  is_ident_start_c(c) || (c >= '0' && c <= '9')
}

///|
/// Builds an ElementDef with the given symbol/type/precedence.
pub fn element_def(
  symbol : String,
  elem_type : TokenType,
  precedence : Int,
) -> ElementDef {
  { symbol, elem_type, precedence }
}

///|
/// The default grammar's element definitions, sorted by symbol length
/// descending — the order the Lexer tries matches in (longest first),
/// mirroring Jexl's `_getSplitRegex`. `-` is deliberately excluded:
/// the Lexer handles it as its own negate/subtract token.
pub fn default_elements() -> Array[ElementDef] {
  [
    // Longest first (length-descending order). `matches` (expr-style
    // regex match) and the mbel extensions `..` (range) and `??`
    // (nil coalescing) are operator elements like the rest.
    element_def("matches", BinaryOp, 20),
    // Two-character elements
    element_def("//", BinaryOp, 40),
    element_def("..", BinaryOp, 25),
    element_def("??", BinaryOp, 500),
    element_def("==", BinaryOp, 20),
    element_def("!=", BinaryOp, 20),
    element_def(">=", BinaryOp, 20),
    element_def("<=", BinaryOp, 20),
    element_def("&&", BinaryOp, 10),
    element_def("||", BinaryOp, 10),
    element_def("in", BinaryOp, 20),
    // Single-character elements
    element_def(".", Dot, 0),
    element_def("[", OpenBracket, 0),
    element_def("]", CloseBracket, 0),
    element_def("|", Pipe, 0),
    element_def("{", OpenCurl, 0),
    element_def("}", CloseCurl, 0),
    element_def(":", Colon, 0),
    element_def(",", Comma, 0),
    element_def("(", OpenParen, 0),
    element_def(")", CloseParen, 0),
    element_def("?", Question, 0),
    element_def("+", BinaryOp, 30),
    element_def("*", BinaryOp, 40),
    element_def("/", BinaryOp, 40),
    element_def("%", BinaryOp, 50),
    element_def("^", BinaryOp, 50),
    element_def(">", BinaryOp, 20),
    element_def("<", BinaryOp, 20),
    element_def("!", UnaryOp, 1000000),
  ]
}

///|
/// Looks up an element definition by symbol.
pub fn find_element(
  elements : Array[ElementDef],
  symbol : String,
) -> ElementDef? {
  for def in elements {
    if def.symbol == symbol {
      return Some(def)
    }
  }
  None
}

///|
/// Looks up an operator's precedence in an element list, falling back
/// to the static default grammar table.
pub fn precedence_of(elements : Array[ElementDef], op : String) -> Int {
  match find_element(elements, op) {
    Some(def) => def.precedence
    None => precedence(op)
  }
}

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
/// Returns the precedence of a default-grammar operator.
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
/// The expr-style aggregate functions whose second argument is a
/// predicate (0-based arg index 1).
pub fn is_aggregate(name : String) -> Bool {
  match name {
    "all" | "none" | "any" | "one" | "filter" | "map" | "count" | "sum" |
    "find" | "findIndex" | "findLast" | "findLastIndex" | "groupBy" |
    "sortBy" | "reduce" =>
      true
    _ => false
  }
}

///|
/// Token types after which a `-` should be interpreted as negation
/// rather than subtraction.  Mirrors Jexl's `minusNegatesAfter`.
pub fn minus_negates_after(t : TokenType) -> Bool {
  match t {
    BinaryOp | UnaryOp | OpenParen | OpenBracket | Question | Colon => true
    _ => false
  }
}
