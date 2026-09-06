// SPDX-License-Identifier: Apache-2.0
// mbel expr package — lexer for the expr-lang dialect.
//
// Full literal family: decimal/hex/octal/binary ints with `_`
// separators, floats with exponents and leading `.5`, single/double
// quoted strings with expr escapes, raw backtick strings, `b"…"`
// byte strings, `//` and `/* */` comments. Keywords are emitted as
// Keyword tokens; the parser decides context (operator vs identifier
// fallback is not needed — expr reserves them).

///|
pub(all) enum TokenKind {
  TkIdent
  TkKeyword
  TkInt
  TkFloat
  TkStr
  TkBytes
  TkOperator
  TkPointer
  TkEOF
} derive(Debug, Eq)

///|
pub struct Token {
  kind : TokenKind
  text : String
  pos : Int
  line : Int
  col : Int
} derive(Debug, Eq)

///|
pub(all) suberror LexError {
  LexErr(String, Int, Int) // message, line, col
}

///|
pub fn tokenize(source : String) -> Array[Token] raise LexError {
  let chars = source.to_array()
  let n = chars.length()
  let out : Array[Token] = []
  let mut i = 0
  let mut line = 1
  let mut line_start = 0
  fn tok(kind : TokenKind, text : String, pos : Int) -> Token {
    { kind, text, pos, line, col: pos - line_start + 1 }
  }
  while i < n {
    let c = chars[i]
    // whitespace & position tracking
    if c == '\n' {
      i += 1
      line += 1
      line_start = i
      continue
    }
    if c == ' ' || c == '\t' || c == '\r' {
      i += 1
      continue
    }
    let pos = i
    // comments
    if c == '/' && i + 1 < n && chars[i + 1] == '/' {
      while i < n && chars[i] != '\n' {
        i += 1
      }
      continue
    }
    if c == '/' && i + 1 < n && chars[i + 1] == '*' {
      i += 2
      let mut closed = false
      while i < n {
        if chars[i] == '\n' {
          line += 1
          line_start = i + 1
        }
        if chars[i] == '*' && i + 1 < n && chars[i + 1] == '/' {
          i += 2
          closed = true
          break
        }
        i += 1
      }
      if !closed {
        raise LexError::LexErr("unclosed comment", line, i - line_start + 1)
      }
      continue
    }
    // identifiers / keywords (b"…" byte strings are handled by the
    // byte-string branch below — never treat `b` as an identifier here)
    if is_ident_start(c) &&
      !((c == 'b' || c == 'B') &&
      i + 1 < n &&
      (chars[i + 1] == '"' || chars[i + 1] == '\'')) {
      let start = i
      while i < n && is_ident_cont(chars[i]) {
        i += 1
      }
      let text = source[start:i].to_owned()
      out.push(tok(keyword_or_ident(text), text, pos))
      continue
    }
    // pointers #, #index, #acc
    if c == '#' {
      let start = i
      i += 1
      while i < n && is_ident_cont(chars[i]) {
        i += 1
      }
      out.push(tok(TkPointer, source[start:i].to_owned(), pos))
      continue
    }
    // byte strings b"…" / b'…' (value is a raw byte sequence)
    if (c == 'b' || c == 'B') &&
      i + 1 < n &&
      (chars[i + 1] == '"' || chars[i + 1] == '\'') {
      let quote = chars[i + 1]
      i += 2
      let buf = StringBuilder::new()
      let mut closed = false
      while i < n {
        let ch = chars[i]
        if ch == '\\' && i + 1 < n {
          i += 1
          let e = chars[i]
          match e {
            'n' => buf.write_char('\n')
            'r' => buf.write_char('\r')
            't' => buf.write_char('\t')
            'a' => buf.write_char('\u{7}')
            'b' => buf.write_char('\u{8}')
            'f' => buf.write_char('\u{C}')
            'v' => buf.write_char('\u{B}')
            '\\' => buf.write_char('\\')
            '\'' => buf.write_char('\'')
            '"' => buf.write_char('"')
            'x' =>
              if i + 2 < n {
                match (hex_val(chars[i + 1]), hex_val(chars[i + 2])) {
                  (Some(h), Some(l)) => {
                    buf.write_char(((h * 16 + l) & 0xFF).unsafe_to_char())
                    i += 2
                  }
                  (_, _) =>
                    raise LexError::LexErr(
                      "invalid \\x escape",
                      line,
                      i - line_start + 1,
                    )
                }
              } else {
                raise LexError::LexErr(
                  "invalid \\x escape",
                  line,
                  i - line_start + 1,
                )
              }
            '0' | '1' | '2' | '3' => {
              // octal escape \NNN, up to \377
              let mut val = e.to_int() - '0'.to_int()
              let mut k = 1
              while k < 3 &&
                    i + k < n &&
                    chars[i + k] >= '0' &&
                    chars[i + k] <= '7' {
                val = val * 8 + (chars[i + k].to_int() - '0'.to_int())
                k += 1
              }
              if val > 255 {
                raise LexError::LexErr(
                  "unable to unescape string",
                  line,
                  i - line_start + 1,
                )
              }
              buf.write_char(val.unsafe_to_char())
              i += k - 1
            }
            _ =>
              raise LexError::LexErr(
                "invalid char escape",
                line,
                i - line_start + 1,
              )
          }
          i += 1
          continue
        }
        if ch == quote {
          i += 1
          closed = true
          break
        }
        if ch == '\n' {
          raise LexError::LexErr(
            "literal not terminated",
            line,
            i - line_start + 1,
          )
        }
        // non-ASCII chars are UTF-8-encoded into the byte sequence
        if ch.to_int() > 127 {
          write_utf8_bytes(buf, ch.to_int())
        } else {
          buf.write_char(ch)
        }
        i += 1
      }
      if !closed {
        raise LexError::LexErr(
          "unterminated byte string",
          line,
          i - line_start + 1,
        )
      }
      out.push(tok(TkBytes, buf.to_string(), pos))
      continue
    }
    // strings (single or double quoted — one shared escape set)
    if c == '"' || c == '\'' {
      let quote = c
      i += 1
      let buf = StringBuilder::new()
      let mut closed = false
      while i < n {
        let ch = chars[i]
        if ch == '\\' && i + 1 < n {
          i += 1
          let e = chars[i]
          match e {
            'n' => buf.write_char('\n')
            'r' => buf.write_char('\r')
            't' => buf.write_char('\t')
            'a' => buf.write_char('\u{7}')
            'b' => buf.write_char('\u{8}')
            'f' => buf.write_char('\u{C}')
            'v' => buf.write_char('\u{B}')
            '`' => buf.write_char('`')
            '\'' => buf.write_char('\'')
            '"' => buf.write_char('"')
            '\\' => buf.write_char('\\')
            'x' =>
              if i + 2 < n {
                match (hex_val(chars[i + 1]), hex_val(chars[i + 2])) {
                  (Some(h), Some(l)) => {
                    buf.write_char((h * 16 + l).unsafe_to_char())
                    i += 2
                  }
                  (_, _) =>
                    raise LexError::LexErr(
                      "invalid \\x escape",
                      line,
                      i - line_start + 1,
                    )
                }
              } else {
                raise LexError::LexErr(
                  "invalid \\x escape",
                  line,
                  i - line_start + 1,
                )
              }
            'u' =>
              if i + 1 < n && chars[i + 1] == '{' {
                // \u{1-6 hex digits}
                let mut j = i + 2
                let mut cp = 0
                let mut digits = 0
                while j < n && chars[j] != '}' && digits < 6 {
                  match hex_val(chars[j]) {
                    Some(h) => {
                      cp = cp * 16 + h
                      digits += 1
                      j += 1
                    }
                    None => break
                  }
                }
                if j < n && chars[j] == '}' && digits > 0 {
                  if cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                    raise LexError::LexErr(
                      "unable to unescape string",
                      line,
                      i - line_start + 1,
                    )
                  }
                  buf.write_char(cp.unsafe_to_char())
                  i = j
                } else {
                  raise LexError::LexErr(
                    "invalid \\u{} escape",
                    line,
                    i - line_start + 1,
                  )
                }
              } else if i + 4 < n {
                // \uXXXX (4 hex digits)
                match
                  (
                    hex_val(chars[i + 1]),
                    hex_val(chars[i + 2]),
                    hex_val(chars[i + 3]),
                    hex_val(chars[i + 4]),
                  ) {
                  (Some(a), Some(b), Some(cc), Some(d)) => {
                    let cp = a * 4096 + b * 256 + cc * 16 + d
                    if cp >= 0xD800 && cp <= 0xDFFF {
                      raise LexError::LexErr(
                        "unable to unescape string",
                        line,
                        i - line_start + 1,
                      )
                    }
                    buf.write_char(cp.unsafe_to_char())
                    i += 4
                  }
                  (_, _, _, _) =>
                    raise LexError::LexErr(
                      "invalid \\u escape",
                      line,
                      i - line_start + 1,
                    )
                }
              } else {
                raise LexError::LexErr(
                  "invalid \\u escape",
                  line,
                  i - line_start + 1,
                )
              }
            'U' =>
              // \UXXXXXXXX (8 hex digits)
              if i + 8 < n {
                let mut cp = 0
                let mut ok = true
                for k in 1..<9 {
                  match hex_val(chars[i + k]) {
                    Some(h) => cp = cp * 16 + h
                    None => ok = false
                  }
                }
                if ok && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) {
                  buf.write_char(cp.unsafe_to_char())
                  i += 8
                } else {
                  raise LexError::LexErr(
                    "invalid \\U escape",
                    line,
                    i - line_start + 1,
                  )
                }
              } else {
                raise LexError::LexErr(
                  "invalid \\U escape",
                  line,
                  i - line_start + 1,
                )
              }
            '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' => {
              // octal escape \NNN (up to 3 digits); \777+ is invalid
              let mut val = e.to_int() - '0'.to_int()
              let mut k = 1
              while k < 3 &&
                    i + k < n &&
                    chars[i + k] >= '0' &&
                    chars[i + k] <= '7' {
                val = val * 8 + (chars[i + k].to_int() - '0'.to_int())
                k += 1
              }
              if val > 255 {
                raise LexError::LexErr(
                  "unable to unescape string",
                  line,
                  i - line_start + 1,
                )
              }
              buf.write_char(val.unsafe_to_char())
              i += k - 1
            }
            _ =>
              raise LexError::LexErr(
                "invalid char escape",
                line,
                i - line_start + 1,
              )
          }
          i += 1
          continue
        }
        if ch == quote {
          i += 1
          closed = true
          break
        }
        if ch == '\n' {
          raise LexError::LexErr(
            "literal not terminated",
            line,
            i - line_start + 1,
          )
        }
        buf.write_char(ch)
        i += 1
      }
      if !closed {
        raise LexError::LexErr("unterminated string", line, i - line_start + 1)
      }
      out.push(tok(TkStr, buf.to_string(), pos))
      continue
    }
    // raw strings `…`
    if c == '`' {
      i += 1
      let buf = StringBuilder::new()
      let mut closed = false
      while i < n {
        if chars[i] == '`' {
          // `` escapes a backtick
          if i + 1 < n && chars[i + 1] == '`' {
            buf.write_char('`')
            i += 2
            continue
          }
          i += 1
          closed = true
          break
        }
        if chars[i] == '\n' {
          line += 1
          line_start = i + 1
        }
        buf.write_char(chars[i])
        i += 1
      }
      if !closed {
        raise LexError::LexErr(
          "unterminated raw string",
          line,
          i - line_start + 1,
        )
      }
      out.push(tok(TkStr, buf.to_string(), pos))
      continue
    }
    // numbers: .5 float, digits (with _ separators, hex/oct/bin, exponent)
    if c == '.' && i + 1 < n && is_digit(chars[i + 1]) {
      let (text, next) = scan_float(chars, i, source)
      out.push(tok(TkFloat, text, pos))
      i = next
      continue
    }
    if is_digit(c) {
      let (kind, text, next) = scan_number(chars, i, source)
      out.push(tok(kind, text, pos))
      i = next
      continue
    }
    // operators (longest first)
    let (op, len) = scan_operator(chars, i, n)
    if len > 0 {
      out.push(tok(TkOperator, op, pos))
      i += len
      continue
    }
    raise LexError::LexErr(
      "unexpected character '" + c.to_string() + "'",
      line,
      i - line_start + 1,
    )
  }
  out.push(tok(TkEOF, "", n))
  out
}

///|
/// Encodes code point `cp` as UTF-8, appending each byte as a 0-255
/// char so a byte string's text is one char per byte.
fn write_utf8_bytes(buf : StringBuilder, cp : Int) -> Unit {
  if cp <= 0x7F {
    buf.write_char(cp.unsafe_to_char())
  } else if cp <= 0x7FF {
    buf.write_char(((0xC0 | (cp >> 6)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | (cp & 0x3F)) & 0xFF).unsafe_to_char())
  } else if cp <= 0xFFFF {
    buf.write_char(((0xE0 | (cp >> 12)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | ((cp >> 6) & 0x3F)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | (cp & 0x3F)) & 0xFF).unsafe_to_char())
  } else {
    buf.write_char(((0xF0 | (cp >> 18)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | ((cp >> 12) & 0x3F)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | ((cp >> 6) & 0x3F)) & 0xFF).unsafe_to_char())
    buf.write_char(((0x80 | (cp & 0x3F)) & 0xFF).unsafe_to_char())
  }
}

///|
fn keyword_or_ident(text : String) -> TokenKind {
  match text {
    "and"
    | "or"
    | "not"
    | "in"
    | "matches"
    | "contains"
    | "startsWith"
    | "endsWith"
    | "let"
    | "if"
    | "else"
    | "true"
    | "false"
    | "nil" => TkKeyword
    _ => TkIdent
  }
}

///|
fn is_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c == '$' ||
  (c >= '\u{C0}' && c <= '\u{D6}') ||
  (c >= '\u{D8}' && c <= '\u{F6}') ||
  (c >= '\u{F8}' && c <= '\u{FF}')
}

///|
fn is_ident_cont(c : Char) -> Bool {
  is_ident_start(c) || is_digit(c)
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn hex_val(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    return Some(c.to_int() - '0'.to_int())
  }
  if c >= 'a' && c <= 'f' {
    return Some(c.to_int() - 'a'.to_int() + 10)
  }
  if c >= 'A' && c <= 'F' {
    return Some(c.to_int() - 'A'.to_int() + 10)
  }
  None
}

///|
/// Operators, longest-match first.
fn scan_operator(chars : Array[Char], i : Int, n : Int) -> (String, Int) {
  let two = if i + 1 < n {
    String::from_array([chars[i], chars[i + 1]])
  } else {
    ""
  }
  match two {
    "??" | "**" | "==" | "!=" | ">=" | "<=" | "&&" | "||" | "?." | ".." =>
      return (two, 2)
    _ => ()
  }
  match chars[i] {
    '+'
    | '-'
    | '*'
    | '/'
    | '%'
    | '^'
    | '>'
    | '<'
    | '!'
    | '?'
    | '|'
    | ':'
    | ','
    | ';'
    | '('
    | ')'
    | '['
    | ']'
    | '{'
    | '}'
    | '.'
    | '=' => (chars[i].to_string(), 1)
    _ => ("", 0)
  }
}

///|
/// Scans `[0-9]*\.[0-9]+([eE][+-]?d+)?` starting at a '.'.
fn scan_float(
  chars : Array[Char],
  start : Int,
  source : String,
) -> (String, Int) {
  let n = chars.length()
  let mut i = start
  if i < n && chars[i] == '.' {
    // leading-dot floats: the caller matched `.` + digit
    i += 1
  }
  while i < n && (is_digit(chars[i]) || chars[i] == '_') {
    i += 1
  }
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    let mut j = i + 1
    if j < n && (chars[j] == '+' || chars[j] == '-') {
      j += 1
    }
    if j < n && is_digit(chars[j]) {
      while j < n && is_digit(chars[j]) {
        j += 1
      }
      i = j
    }
  }
  (strip_underscores(source[start:i].to_owned()), i)
}

///|
/// Scans an integer or float starting at a digit. Handles 0x/0o/0b
/// prefixes, `_` separators, fraction and exponent.
fn scan_number(
  chars : Array[Char],
  start : Int,
  source : String,
) -> (TokenKind, String, Int) {
  let n = chars.length()
  let c0 = chars[start]
  // radix prefixes
  if c0 == '0' && start + 1 < n {
    match chars[start + 1] {
      'x' | 'X' => {
        let mut i = start + 2
        while i < n && (hex_val(chars[i]) is Some(_) || chars[i] == '_') {
          i += 1
        }
        let text = strip_underscores(source[start + 2:i].to_owned())
        let v = parse_radix(text, 16)
        return (TkInt, "int:" + v.to_string(), i)
      }
      'o' | 'O' => {
        let mut i = start + 2
        while i < n && ((chars[i] >= '0' && chars[i] <= '7') || chars[i] == '_') {
          i += 1
        }
        let text = strip_underscores(source[start + 2:i].to_owned())
        let v = parse_radix(text, 8)
        return (TkInt, "int:" + v.to_string(), i)
      }
      'b' | 'B' => {
        let mut i = start + 2
        while i < n && (chars[i] == '0' || chars[i] == '1' || chars[i] == '_') {
          i += 1
        }
        let text = strip_underscores(source[start + 2:i].to_owned())
        let v = parse_radix(text, 2)
        return (TkInt, "int:" + v.to_string(), i)
      }
      _ => ()
    }
  }
  let mut i = start
  while i < n && (is_digit(chars[i]) || chars[i] == '_') {
    i += 1
  }
  let mut is_float = false
  if i < n && chars[i] == '.' && i + 1 < n && is_digit(chars[i + 1]) {
    is_float = true
    i += 1
    while i < n && (is_digit(chars[i]) || chars[i] == '_') {
      i += 1
    }
  }
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    let mut j = i + 1
    if j < n && (chars[j] == '+' || chars[j] == '-') {
      j += 1
    }
    if j < n && is_digit(chars[j]) {
      is_float = true
      while j < n && is_digit(chars[j]) {
        j += 1
      }
      i = j
    }
  }
  let raw = strip_underscores(source[start:i].to_owned())
  if is_float {
    let d = parse_float_str(raw)
    (TkFloat, "float:" + d.to_string(), i)
  } else {
    let v = parse_radix(raw, 10)
    (TkInt, "int:" + v.to_string(), i)
  }
}

///|
fn strip_underscores(s : String) -> String {
  let mut has_us = false
  for c in s {
    if c == '_' {
      has_us = true
      break
    }
  }
  if !has_us {
    return s
  }
  let out = StringBuilder::new()
  for c in s {
    if c != '_' {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Radix string to Int64 (digits assumed valid for the radix).
fn parse_radix(digits : String, radix : Int) -> Int64 {
  let mut v = 0L
  let base = radix.to_int64()
  for c in digits {
    match hex_val(c) {
      Some(h) => v = v * base + h.to_int64()
      None => ()
    }
  }
  v
}

///|
/// Float parsing for the expr lexer: mantissa digits as one integer,
/// then a single power-of-ten scaling (correctly rounded for typical
/// literals, like the engine's parse_decimal).
fn parse_float_str(raw : String) -> Double {
  let chars = raw.to_array()
  let n = chars.length()
  let mut i = 0
  let mut mantissa = 0.0
  let mut frac_len = 0
  while i < n && is_digit(chars[i]) {
    mantissa = mantissa * 10.0 + (chars[i].to_int() - '0'.to_int()).to_double()
    i += 1
  }
  if i < n && chars[i] == '.' {
    i += 1
    while i < n && is_digit(chars[i]) {
      mantissa = mantissa * 10.0 +
        (chars[i].to_int() - '0'.to_int()).to_double()
      frac_len += 1
      i += 1
    }
  }
  let mut e10 = -frac_len
  if i < n && (chars[i] == 'e' || chars[i] == 'E') {
    i += 1
    let mut eneg = false
    if i < n && (chars[i] == '+' || chars[i] == '-') {
      eneg = chars[i] == '-'
      i += 1
    }
    let mut exp = 0
    while i < n && is_digit(chars[i]) {
      exp = exp * 10 + (chars[i].to_int() - '0'.to_int())
      i += 1
    }
    e10 += if eneg { -exp } else { exp }
  }
  let mut p = 1.0
  for _ in 0..<(if e10 < 0 { -e10 } else { e10 }) {
    p = p * 10.0
  }
  if e10 < 0 {
    mantissa / p
  } else {
    mantissa * p
  }
}
