// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — string helpers.
//
// upper/lower are ASCII-only (expr uses full Unicode via Go's
// strings.ToUpper); a Unicode case-mapper is a follow-up item.

///|
fn to_str(v : @ast.Value, name : String) -> String raise @evaluator.EvalError {
  match v {
    @ast.StrVal(s) => s
    _ => raise @evaluator.EvalErr(name + ": expected a string")
  }
}

///|
fn to_upper_ascii(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'a' && c <= 'z' {
      out.write_char((c.to_int() - 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
fn to_lower_ascii(s : String) -> String {
  let out = StringBuilder::new()
  for c in s {
    if c >= 'A' && c <= 'Z' {
      out.write_char((c.to_int() + 32).unsafe_to_char())
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// Go strings.Replace (all occurrences; empty old inserts between
/// each UTF-16 unit, matching Go only for empty-sep edge cases).
fn replace_all(s : String, old : String, new : String) -> String {
  if old == "" {
    return s
  }
  let out = StringBuilder::new()
  let n = s.length()
  let m = old.length()
  let mut i = 0
  while i < n {
    if i + m <= n && s[i:i + m].to_owned() == old {
      out.write_string(new)
      i += m
    } else {
      out.write_char(s[i].to_int().unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// Last index of sub in s, or -1.
fn last_index_of(s : String, sub : String) -> Int {
  if sub == "" {
    return s.length()
  }
  let chars = s.to_array()
  let sub_chars = sub.to_array()
  let n = chars.length()
  let m = sub_chars.length()
  if m > n {
    return -1
  }
  let mut i = n - m
  while i >= 0 {
    let mut ok = true
    for j in 0..<m {
      if chars[i + j] != sub_chars[j] {
        ok = false
        break
      }
    }
    if ok {
      return i
    }
    i -= 1
  }
  -1
}
