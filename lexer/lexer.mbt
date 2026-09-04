// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// lexer package: tokenization of Jexl expression strings
//
// Ported from Jexl's lib/Lexer.js.  The original uses a single split-regex
// built from the grammar elements; MoonBit has no regex split, so this is
// a hand-written character scanner that produces the same token stream.
//
// Key behaviors preserved from Jexl:
//   - String literals (single/double quoted) with escape processing
//   - Numeric literals (int/float, negative via context-dependent `-`)
//   - Boolean literals (true/false)
//   - Identifiers (letters, digits, underscore, $, Cyrillic, Latin-1 Supplement)
//   - Grammar elements / operators / control characters
//   - Whitespace appended to previous token's `raw`
//   - Context-dependent `-` as negate vs subtract (minusNegatesAfter)
//   - Returns Err on invalid tokens

///|
/// The value of a literal token — boolean, number, or string.
/// For non-literal tokens, `Str` holds the raw operator/element string.
pub(all) enum LiteralValue {
  Bool(Bool)
  Num(Double)
  Str(String)
} derive(Debug)

///|
/// A token produced by the Lexer.
pub struct Token {
  typ : @grammar.TokenType
  value : LiteralValue
  raw : String
} derive(Debug)

///|
/// Tokenizes a Jexl expression string into an array of tokens.
///
/// This is the public entry point, equivalent to Jexl's `Lexer.tokenize`.
/// Returns `Err(msg)` on invalid tokens.
pub fn tokenize(input : String) -> Result[Array[Token], String] {
  let chars = input.to_array()
  let n = chars.length()
  let tokens : Array[Token] = []
  let mut pos = 0
  let mut negate = false

  while pos < n {
    let c = chars[pos]

    // Whitespace
    if is_space(c) {
      let mut ws_end = pos
      while ws_end < n && is_space(chars[ws_end]) {
        ws_end += 1
      }
      let ws = input[pos:ws_end].to_owned()
      if tokens.length() > 0 {
        // Append to previous token's raw
        let last = tokens[tokens.length() - 1]
        tokens[tokens.length() - 1] = Token::{
          typ: last.typ,
          value: last.value,
          raw: last.raw + ws,
        }
      }
      pos = ws_end
      continue
    }

    // Context-dependent minus (negate vs subtract)
    if c == '-' {
      let should_negate = if tokens.length() == 0 {
        true
      } else {
        @grammar.minus_negates_after(tokens[tokens.length() - 1].typ)
      }
      if should_negate {
        negate = true
        pos += 1
        continue
      }
      // It's a binaryOp subtract
      tokens.push(Token::{ typ: @grammar.BinaryOp, value: Str("-"), raw: "-" })
      pos += 1
      continue
    }

    // String literal
    if c == '"' || c == '\'' {
      match scan_string(chars, pos) {
        Ok((raw, end)) => {
          let final_raw = if negate {
            negate = false
            "-" + raw
          } else {
            raw
          }
          match create_token(final_raw) {
            Ok(t) => tokens.push(t)
            Err(msg) => return Err(msg)
          }
          pos = end
        }
        Err(msg) => return Err(msg)
      }
      continue
    }

    // Boolean keyword (true/false)
    match match_boolean(chars, pos) {
      Some((raw, val)) => {
        if negate {
          negate = false
          match create_token("-" + raw) {
            Ok(t) => tokens.push(t)
            Err(msg) => return Err(msg)
          }
        } else {
          tokens.push(Token::{ typ: @grammar.Literal, value: Bool(val), raw })
        }
        pos += raw.length()
        continue
      }
      None => ()
    }

    // `in` keyword (binary operator)
    if is_in_keyword(chars, pos) {
      if negate {
        negate = false
        match create_token("-in") {
          Ok(t) => tokens.push(t)
          Err(msg) => return Err(msg)
        }
      } else {
        tokens.push(Token::{
          typ: @grammar.BinaryOp,
          value: Str("in"),
          raw: "in",
        })
      }
      pos += 2
      continue
    }

    // Numeric literal
    if is_digit(c) {
      let (raw, end) = scan_number(chars, pos)
      // Jexl's regex approach treats "9foo" as a single element that matches
      // neither the numeric nor identifier regex, so it throws. Detect a digit
      // run immediately followed by identifier chars (no separator) and reject.
      if end < n && is_ident_start(chars[end]) {
        let (id_raw, _) = scan_identifier(chars, end)
        return Err("Invalid expression token: " + raw + id_raw)
      }
      let final_raw = if negate {
        negate = false
        "-" + raw
      } else {
        raw
      }
      match create_token(final_raw) {
        Ok(t) => tokens.push(t)
        Err(msg) => return Err(msg)
      }
      pos = end
      continue
    }

    // Grammar element (operators and control characters)
    match match_element(chars, pos) {
      Some(elem) => {
        if negate {
          negate = false
          match create_token("-" + elem) {
            Ok(t) => tokens.push(t)
            Err(msg) => return Err(msg)
          }
        } else {
          match create_token(elem) {
            Ok(t) => tokens.push(t)
            Err(msg) => return Err(msg)
          }
        }
        pos += elem.length()
        continue
      }
      None => ()
    }

    // Identifier
    if is_ident_start(c) {
      let (raw, end) = scan_identifier(chars, pos)
      let final_raw = if negate {
        negate = false
        "-" + raw
      } else {
        raw
      }
      match create_token(final_raw) {
        Ok(t) => tokens.push(t)
        Err(msg) => return Err(msg)
      }
      pos = end
      continue
    }

    // Unrecognized character
    return Err("Invalid expression token: " + c.to_string())
  }

  // Catch a trailing `-` (negate flag set but no following element)
  if negate {
    match create_token("-") {
      Ok(t) => tokens.push(t)
      Err(msg) => return Err(msg)
    }
  }

  Ok(tokens)
}

// --- Character classification ---

///|
fn is_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= 'а' && c <= 'я') ||
  (c >= 'А' && c <= 'Я') ||
  c == '_' ||
  c == '$' ||
  (c >= '\u00C0' && c <= '\u00D6') ||
  (c >= '\u00D8' && c <= '\u00F6') ||
  (c >= '\u00F8' && c <= '\u00FF')
}

///|
fn is_ident_cont(c : Char) -> Bool {
  is_ident_start(c) || (c >= '0' && c <= '9')
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn is_space(c : Char) -> Bool {
  match c {
    ' ' | '\t' | '\n' | '\r' | '\u000B' | '\u000C' | '\u00A0' | '\uFEFF' => true
    _ => false
  }
}

// --- Element/keyword matching ---

///|
/// Tries to match a grammar element at the current position.
/// Longer operators are matched first (e.g. `//` before `/`, `<=` before `<`).
fn match_element(chars : Array[Char], pos : Int) -> String? {
  let n = chars.length()
  let remaining = n - pos
  // Two-char operators: //, !=, &&, <=, ==, >=, ||
  if remaining >= 2 {
    match String::from_array([chars[pos], chars[pos + 1]]) {
      "//" | "!=" | "&&" | "<=" | "==" | ">=" | "||" as two => return Some(two)
      _ => ()
    }
  }
  // One-char elements
  match chars[pos] {
    '+'
    | '-'
    | '*'
    | '/'
    | '%'
    | '^'
    | '>'
    | '<'
    | '!'
    | '.'
    | '['
    | ']'
    | '|'
    | '{'
    | '}'
    | ':'
    | ','
    | '('
    | ')'
    | '?' as c => Some(c.to_string())
    _ => None
  }
}

///|
/// Checks if `in` keyword appears at pos (not followed by identifier chars).
fn is_in_keyword(chars : Array[Char], pos : Int) -> Bool {
  let n = chars.length()
  if pos + 2 > n {
    return false
  }
  if chars[pos] == 'i' && chars[pos + 1] == 'n' {
    if pos + 2 < n && is_ident_cont(chars[pos + 2]) {
      return false
    }
    return true
  }
  false
}

///|
/// Matches `true` or `false` at pos (word-boundary check).
fn match_boolean(chars : Array[Char], pos : Int) -> (String, Bool)? {
  let n = chars.length()
  // true
  if pos + 4 <= n &&
    chars[pos] == 't' &&
    chars[pos + 1] == 'r' &&
    chars[pos + 2] == 'u' &&
    chars[pos + 3] == 'e' {
    if pos + 4 < n && is_ident_cont(chars[pos + 4]) {
      return None
    }
    return Some(("true", true))
  }
  // false
  if pos + 5 <= n &&
    chars[pos] == 'f' &&
    chars[pos + 1] == 'a' &&
    chars[pos + 2] == 'l' &&
    chars[pos + 3] == 's' &&
    chars[pos + 4] == 'e' {
    if pos + 5 < n && is_ident_cont(chars[pos + 5]) {
      return None
    }
    return Some(("false", false))
  }
  None
}

// --- Scanners ---

///|
/// Scans a string literal starting at `pos` (the opening quote).
/// Returns (raw_string_including_quotes, end_pos_after_closing_quote).
fn scan_string(chars : Array[Char], pos : Int) -> Result[(String, Int), String] {
  let n = chars.length()
  let quote = chars[pos]
  let buf = StringBuilder::new()
  buf.write_char(quote)
  let mut i = pos + 1
  while i < n {
    let c = chars[i]
    if c == '\\' && i + 1 < n {
      // Keep backslash + next char in raw form
      buf.write_char(c)
      buf.write_char(chars[i + 1])
      i += 2
      continue
    }
    buf.write_char(c)
    if c == quote {
      return Ok((buf.to_string(), i + 1))
    }
    i += 1
  }
  Err("Unterminated string literal")
}

///|
/// Scans a numeric literal starting at `pos` (no sign — caller handles negation).
fn scan_number(chars : Array[Char], pos : Int) -> (String, Int) {
  let n = chars.length()
  let buf = StringBuilder::new()
  let mut i = pos
  // [0-9]*
  while i < n && is_digit(chars[i]) {
    buf.write_char(chars[i])
    i += 1
  }
  // \.[0-9]+
  if i < n && chars[i] == '.' {
    if i + 1 < n && is_digit(chars[i + 1]) {
      buf.write_char('.')
      i += 1
      while i < n && is_digit(chars[i]) {
        buf.write_char(chars[i])
        i += 1
      }
    }
  }
  (buf.to_string(), i)
}

///|
/// Scans an identifier starting at `pos`.
fn scan_identifier(chars : Array[Char], pos : Int) -> (String, Int) {
  let n = chars.length()
  let buf = StringBuilder::new()
  let mut i = pos
  while i < n && is_ident_cont(chars[i]) {
    buf.write_char(chars[i])
    i += 1
  }
  (buf.to_string(), i)
}

// ---Token creation ---

///|
/// Checks whether a string matches Jexl's numeric regex:
///   /^-?(?:(?:[0-9]*\.[0-9]+)|[0-9]+)$/
fn is_numeric(s : String) -> Bool {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return false
  }
  let mut i = 0
  if chars[0] == '-' {
    i = 1
    if i >= n {
      return false
    }
  }
  let mut has_dot = false
  let mut has_digits_before = false
  let mut has_digits_after = false
  // [0-9]* before optional dot
  while i < n && is_digit(chars[i]) {
    has_digits_before = true
    i += 1
  }
  // Optional \.[0-9]+
  if i < n && chars[i] == '.' {
    has_dot = true
    i += 1
    while i < n && is_digit(chars[i]) {
      has_digits_after = true
      i += 1
    }
  }
  if i != n {
    return false
  }
  if has_dot {
    return has_digits_after
  }
  return has_digits_before
}

///|
/// Parses a validated numeric string into a Double.
/// `is_numeric` must have already confirmed the format; this is a simple
/// integer/decimal parser (no scientific notation needed — Jexl doesn't
/// support it in the lexer either).
fn parse_double(s : String) -> Result[Double, String] {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return Err("empty")
  }
  let mut i = 0
  let mut neg = false
  if chars[0] == '-' {
    neg = true
    i = 1
  }
  let mut result = 0.0
  // Integer part [0-9]*
  while i < n && is_digit(chars[i]) {
    result = result * 10.0 + (chars[i].to_int() - '0'.to_int()).to_double()
    i += 1
  }
  // Fractional part \.[0-9]+
  if i < n && chars[i] == '.' {
    i += 1
    let mut scale = 0.1
    while i < n && is_digit(chars[i]) {
      result += (chars[i].to_int() - '0'.to_int()).to_double() * scale
      scale *= 0.1
      i += 1
    }
  }
  Ok(if neg { -result } else { result })
}

///|
/// Checks whether a string matches Jexl's identRegex.
fn is_identifier(s : String) -> Bool {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return false
  }
  if !is_ident_start(chars[0]) {
    return false
  }
  for c in chars {
    if !is_ident_cont(c) {
      return false
    }
  }
  true
}

///|
/// Unquotes a string literal, processing escape sequences.
/// Mirrors Jexl's `_unquote`: strip quotes, \\quote -> quote, \\\\ -> \\
fn unquote(str : String) -> String {
  let chars = str.to_array()
  let n = chars.length()
  if n < 2 {
    return str
  }
  let quote = chars[0]
  let inner = str[1:n - 1].to_owned()
  let inner_chars = inner.to_array()
  let m = inner_chars.length()
  let buf = StringBuilder::new()
  let mut i = 0
  while i < m {
    let c = inner_chars[i]
    if c == '\\' && i + 1 < m {
      let next = inner_chars[i + 1]
      if next == quote {
        buf.write_char(quote)
        i += 2
        continue
      } else if next == '\\' {
        buf.write_char('\\')
        i += 2
        continue
      }
    }
    buf.write_char(c)
    i += 1
  }
  buf.to_string()
}

///|
/// Creates a token from a raw element string. Mirrors Jexl's `_createToken`.
fn create_token(element : String) -> Result[Token, String] {
  let chars = element.to_array()
  if chars.length() == 0 {
    return Err("Invalid expression token: (empty)")
  }
  let first = chars[0]

  // String literal
  if first == '"' || first == '\'' {
    let val = unquote(element)
    return Ok(Token::{ typ: @grammar.Literal, value: Str(val), raw: element })
  }

  // Numeric
  if is_numeric(element) {
    match parse_double(element) {
      Ok(d) =>
        return Ok(Token::{ typ: @grammar.Literal, value: Num(d), raw: element })
      Err(_) => return Err("Invalid expression token: " + element)
    }
  }

  // Boolean
  if element == "true" {
    return Ok(Token::{ typ: @grammar.Literal, value: Bool(true), raw: element })
  }
  if element == "false" {
    return Ok(Token::{ typ: @grammar.Literal, value: Bool(false), raw: element })
  }

  // Grammar element (operator/control char)
  match @grammar.element_type(element) {
    Some(t) => return Ok(Token::{ typ: t, value: Str(element), raw: element })
    None => ()
  }

  // Identifier
  if is_identifier(element) {
    return Ok(Token::{
      typ: @grammar.Identifier,
      value: Str(element),
      raw: element,
    })
  }

  Err("Invalid expression token: " + element)
}
