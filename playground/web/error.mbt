// SPDX-License-Identifier: Apache-2.0
// mbel playground — structured error envelope (proposal 0003, P3).
//
// Every JSON export reports a failure as
//
//   {"$error": "<message>", "$code": "<CODE>", "$pos": {"line": L, "col": C}}
//
// The message text is byte-identical to the pre-0.5.0 envelope, so hosts
// that match on prose keep working; `$code` is the stable thing to branch
// on. `$pos` is present only where the source text carries a position
// (parse errors and Compile-mode checker errors) — the engine-level
// "unknown name x" walks the lowered legacy AST and has none.
//
// Codes are assigned from the contract-locked message shapes (AGENTS.md
// fixes the wording) plus the boundary stage that produced the error.
// Renaming a code or changing a message without updating this table is a
// bug: tools/check_abi.mjs asserts one case per family.

///|
/// The full envelope for an engine-produced message.
fn error_out(msg : String) -> String {
  code_out(msg, code_of(msg))
}

///|
/// The envelope for a boundary stage that already knows its code
/// (host input, functions file, session handle, limits).
fn code_out(msg : String, code : String) -> String {
  code_out_at(msg, code, pos_of(msg))
}

///|
/// Envelope builder; `pos` is omitted from the JSON when None.
fn code_out_at(msg : String, code : String, pos : (Int32, Int32)?) -> String {
  let out = StringBuilder::new()
  out.write_string("{\"$error\":")
  out.write_string(canon_str(msg))
  out.write_string(",\"$code\":")
  out.write_string(canon_str(code))
  match pos {
    Some((line, col)) => {
      out.write_string(",\"$pos\":{\"line\":")
      out.write_string(line.to_string())
      out.write_string(",\"col\":")
      out.write_string(col.to_string())
      out.write_string("}")
    }
    None => ()
  }
  out.write_string("}")
  out.to_string()
}

///|
/// Maps an engine message to its stable code. Order matters: the parse
/// family is tested before the generic budget shapes because a parse
/// budget failure is reported *inside* a "parse error at L:C:" prefix.
fn code_of(msg : String) -> String {
  if msg.contains("parse error at ") {
    if msg.contains("too large") {
      "PARSE_TOO_LARGE"
    } else if msg.contains("too deeply nested") {
      "PARSE_TOO_DEEP"
    } else {
      "PARSE_SYNTAX"
    }
  } else if msg == "Cannot evaluate an empty expression" {
    "PARSE_EMPTY"
  } else if msg.contains("expression is too large") {
    "PARSE_TOO_LARGE"
  } else if msg.contains("expression is too deeply nested") {
    "PARSE_TOO_DEEP"
  } else if msg.contains("memory budget exceeded") ||
    msg.contains("expression is too deep") ||
    msg.contains("max depth reached") ||
    msg.contains("value nesting too deep") {
    "RUNTIME_BUDGET"
  } else if msg.contains("function call depth exceeded") {
    "RUNTIME_RECURSION"
  } else if msg.contains("unknown name ") {
    "CHECK_UNKNOWN_NAME"
  } else if msg.contains("unknown function ") {
    "CHECK_UNKNOWN_FUNCTION"
  } else if msg.contains("invalid number of arguments") {
    "CHECK_ARITY"
  } else if msg.contains("Jexl Function ") && msg.contains("is not defined") {
    "RUNTIME_UNKNOWN_CALL"
  } else if msg.contains("(mismatched type") {
    // Compile mode spells the operand types: "(mismatched types int and
    // string)"; Eval mode spells the operation: "int + string".
    "CHECK_TYPE"
  } else if msg.contains("invalid operation") {
    "RUNTIME_TYPE"
  } else if msg.has_prefix("function \"") {
    // A body failure that matched no more specific shape.
    "CHECK_FUNC_BODY"
  } else {
    "INTERNAL"
  }
}

///|
/// Functions-file validation errors carry two distinct remedies: a
/// malformed document is `FUNCS_JSON`, an unsupported `version` is
/// `FUNCS_VERSION`. Semantic registration failures (bad name, duplicate,
/// invalid parameter) are `FUNCS_INVALID` and are mapped by the caller.
fn functions_file_code(msg : String) -> String {
  if msg.contains("unsupported version") || msg.contains("missing \"version\"") {
    "FUNCS_VERSION"
  } else {
    "FUNCS_JSON"
  }
}

///|
/// Registration failures: keep a specific checker code when the message
/// carries one, otherwise the definition itself is invalid.
fn registration_code(msg : String) -> String {
  let code = code_of(msg)
  if code == "INTERNAL" {
    "FUNCS_INVALID"
  } else {
    code
  }
}

///|
/// Extracts a source position from a message, when one is embedded.
/// Two shapes exist: "parse error at L:C: ..." (parse stage) and expr's
/// FileError layout "msg (L:C)\n | source\n | ..^" (Compile mode).
fn pos_of(msg : String) -> (Int32, Int32)? {
  let chars = msg.to_array()
  let parse_prefix = "parse error at "
  if msg.has_prefix(parse_prefix) {
    return pair_at(chars, parse_prefix.length())
  }
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '(' {
      match pair_at(chars, i + 1) {
        Some(p) => return Some(p)
        None => ()
      }
    }
    i = i + 1
  }
  None
}

///|
/// Reads `L:C` at `start`, requiring a `)` or `:` right after the column
/// so unrelated parenthesised numbers are not mistaken for positions.
fn pair_at(chars : Array[Char], start : Int32) -> (Int32, Int32)? {
  match read_digits(chars, start) {
    None => None
    Some((line, after_line)) =>
      if after_line < chars.length() && chars[after_line] == ':' {
        match read_digits(chars, after_line + 1) {
          None => None
          Some((col, after_col)) =>
            if after_col < chars.length() &&
              (chars[after_col] == ')' || chars[after_col] == ':') {
              Some((line, col))
            } else {
              None
            }
        }
      } else {
        None
      }
  }
}

///|
/// Reads a run of ASCII digits; returns the value and the index after it.
fn read_digits(chars : Array[Char], start : Int32) -> (Int32, Int32)? {
  if start < 0 || start >= chars.length() {
    return None
  }
  let mut i = start
  let mut value = 0
  while i < chars.length() && chars[i] >= '0' && chars[i] <= '9' {
    value = value * 10 + (chars[i].to_int() - 48)
    i = i + 1
  }
  if i == start {
    None
  } else {
    Some((value, i))
  }
}
