// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// evaluator package: value semantics compatibility layer.
//
// JS semantics ported from Jexl's grammar.js eval functions. These
// helpers approximate JavaScript coercion rules (==, truthiness,
// ToNumber/ToString) so expression results match Jexl. Divergences
// (structural object identity, exotic ToPrimitive cases) are documented
// in docs/parity-contract.md.
//
// This is the compatibility layer for JS value semantics: every helper
// here exists only to mirror a JS runtime behavior that MoonBit does
// not have natively. Review each one against docs/parity-contract.md
// before changing.

///|
/// JS ToBoolean — falsy: false, 0, NaN, "", null, undefined.
/// Arrays and objects are always truthy (even empty).
pub fn truthy(v : @ast.Value) -> Bool {
  match v {
    @ast.BoolVal(b) => b
    @ast.NumVal(d) => d != 0.0 && d == d
    @ast.StrVal(s) => s != ""
    @ast.NullVal | @ast.UndefVal => false
    @ast.ArrayVal(_) | @ast.ObjectVal(_) => true
  }
}

///|
/// JS strict equality (===): type-strict, NaN !== NaN.
/// Objects compare structurally here (JS compares identity; see docs).
pub fn strict_eq(a : @ast.Value, b : @ast.Value) -> Bool {
  match (a, b) {
    (@ast.NumVal(x), @ast.NumVal(y)) => x == y
    (@ast.StrVal(x), @ast.StrVal(y)) => x == y
    (@ast.BoolVal(x), @ast.BoolVal(y)) => x == y
    (@ast.NullVal, @ast.NullVal) => true
    (@ast.UndefVal, @ast.UndefVal) => true
    (@ast.ArrayVal(x), @ast.ArrayVal(y)) => value_arr_eq(x, y)
    (@ast.ObjectVal(x), @ast.ObjectVal(y)) => value_obj_eq(x, y)
    (_, _) => false
  }
}

///|
/// JS abstract equality (==) with string/number/boolean coercion.
fn value_arr_eq(x : Array[@ast.Value], y : Array[@ast.Value]) -> Bool {
  if x.length() != y.length() {
    return false
  }
  for i in 0..<x.length() {
    if !strict_eq(x[i], y[i]) {
      return false
    }
  }
  true
}

///|
fn value_obj_eq(
  x : Array[(String, @ast.Value)],
  y : Array[(String, @ast.Value)],
) -> Bool {
  if x.length() != y.length() {
    return false
  }
  for i in 0..<x.length() {
    let (kx, vx) = x[i]
    let (ky, vy) = y[i]
    if kx != ky || !strict_eq(vx, vy) {
      return false
    }
  }
  true
}

///|
/// JS ToNumber — bool→0/1, null→0, ""→0, numeric strings parsed,
/// undefined/unparseable→NaN. (Jexl equality and arithmetic rely on it.)
pub fn to_number(v : @ast.Value) -> Double {
  match v {
    @ast.BoolVal(b) => if b { 1.0 } else { 0.0 }
    @ast.NumVal(d) => d
    @ast.StrVal(s) => str_to_number(s)
    @ast.NullVal => 0.0
    @ast.UndefVal => nan()
    @ast.ArrayVal(_) | @ast.ObjectVal(_) => nan()
  }
}

///|
/// Parses a numeric string the way JS ToNumber does for the cases Jexl
/// exercises: "", whitespace, and plain decimal numbers.
pub fn str_to_number(s : String) -> Double {
  let t = s.trim().to_owned()
  if t == "" {
    return 0.0
  }
  parse_decimal(t)
}

///|
/// Parses a plain decimal string ("-1.5", "20") into a Double.
/// Returns NaN for anything else (no hex/exponent support, matching
/// the cases the Jexl suites exercise).
pub fn parse_decimal(s : String) -> Double {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return nan()
  }
  let mut i = 0
  let mut neg = false
  if chars[0] == '+' || chars[0] == '-' {
    neg = chars[0] == '-'
    i = 1
  }
  if i >= n {
    return nan()
  }
  let mut result = 0.0
  let mut digits = 0
  while i < n && is_digit(chars[i]) {
    result = result * 10.0 + (chars[i].to_int() - '0'.to_int()).to_double()
    digits += 1
    i += 1
  }
  if i < n && chars[i] == '.' {
    i += 1
    let mut scale = 0.1
    while i < n && is_digit(chars[i]) {
      result += (chars[i].to_int() - '0'.to_int()).to_double() * scale
      scale *= 0.1
      i += 1
    }
  }
  if i != n || digits == 0 {
    return nan()
  }
  if neg {
    -result
  } else {
    result
  }
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// NaN — JS results that are not numbers land here (0/0, "abc"-1, ...).
pub fn nan() -> Double {
  0.0 / 0.0
}

///|
/// JS ToString for primitives — numbers use shortest formatting, which
/// MoonBit's Double::to_string matches for the values Jexl uses.
pub fn to_string(v : @ast.Value) -> String {
  match v {
    @ast.BoolVal(b) => if b { "true" } else { "false" }
    @ast.NumVal(d) => d.to_string()
    @ast.StrVal(s) => s
    @ast.NullVal => "null"
    @ast.UndefVal => "undefined"
    @ast.ArrayVal(xs) => arr_to_string(xs)
    @ast.ObjectVal(_) => "[object Object]"
  }
}

///|
/// JS Array.prototype.toString — elements joined with "," after
/// ToString coercion.
fn arr_to_string(xs : Array[@ast.Value]) -> String {
  let parts = xs.map(to_string)
  let mut out = ""
  let mut first = true
  for p in parts {
    if first {
      first = false
    } else {
      out = out + ","
    }
    out = out + p
  }
  out
}

///|
/// JS loose equality (==). Handles the coercions Jexl expressions hit:
/// null==undefined, number/string coercion, boolean coercion.
pub fn loose_eq(a : @ast.Value, b : @ast.Value) -> Bool {
  match (a, b) {
    (@ast.NullVal, @ast.UndefVal) => true
    (@ast.UndefVal, @ast.NullVal) => true
    (@ast.NullVal, @ast.NullVal) => true
    (@ast.UndefVal, @ast.UndefVal) => true
    (_, @ast.NullVal) => false
    (@ast.NullVal, _) => false
    (_, @ast.UndefVal) => false
    (@ast.UndefVal, _) => false
    (@ast.BoolVal(x), y) => loose_eq(@ast.NumVal(if x { 1.0 } else { 0.0 }), y)
    (x, @ast.BoolVal(y)) => loose_eq(x, @ast.NumVal(if y { 1.0 } else { 0.0 }))
    (@ast.StrVal(x), @ast.NumVal(y)) => str_to_number(x) == y
    (@ast.NumVal(x), @ast.StrVal(y)) => x == str_to_number(y)
    (@ast.StrVal(x), @ast.StrVal(y)) => x == y
    (@ast.NumVal(x), @ast.NumVal(y)) => x == y
    (@ast.StrVal(_), _) => false
    (_, @ast.StrVal(_)) => false
    (_, _) => strict_eq(a, b)
  }
}

///|
/// JS relational comparison semantics for `< <= > >=`:
/// both strings → lexicographic; otherwise numeric with NaN → false.
pub fn compare(op : String, a : @ast.Value, b : @ast.Value) -> Bool {
  match (a, b) {
    (@ast.StrVal(x), @ast.StrVal(y)) => {
      let c = x.compare(y)
      match op {
        "<" => c < 0
        "<=" => c <= 0
        ">" => c > 0
        _ => c >= 0
      }
    }
    (_, _) => {
      let x = to_number(a)
      let y = to_number(b)
      if x == nan() || y == nan() || x != x || y != y {
        return false
      }
      match op {
        "<" => x < y
        "<=" => x <= y
        ">" => x > y
        _ => x >= y
      }
    }
  }
}

///|
/// JS remainder semantics (sign of dividend). MoonBit Double has no %,
/// so: a - trunc(a/b) * b.
pub fn remainder(a : Double, b : Double) -> Double {
  if b == 0.0 {
    return nan()
  }
  let q = a / b
  let trunc_q = if q < 0.0 { -(-q).floor() } else { q.floor() }
  a - trunc_q * b
}

///|
/// Finds the first index of `sub` in `s`, or -1 (String.indexOf).
pub fn index_of(s : String, sub : String) -> Int {
  if sub == "" {
    return 0
  }
  let chars = s.to_array()
  let sub_chars = sub.to_array()
  let n = chars.length()
  let m = sub_chars.length()
  if m > n {
    return -1
  }
  for i in 0..<(n - m + 1) {
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
  }
  -1
}
