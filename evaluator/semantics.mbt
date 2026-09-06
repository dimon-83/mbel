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
    @ast.IntVal(i) => i != 0L
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
    (@ast.IntVal(x), @ast.IntVal(y)) => x == y
    // typed integers are distinct kinds from doubles (expr DeepEqual)
    (@ast.IntVal(_), _) | (_, @ast.IntVal(_)) => false
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
    @ast.IntVal(i) => i.to_double()
    @ast.StrVal(s) => str_to_number(s)
    @ast.NullVal => 0.0
    @ast.UndefVal => nan()
    // JS ToNumber on arrays runs them through ToPrimitive (join):
    // [] -> "" -> 0, [5] -> "5" -> 5, [1,2] -> "1,2" -> NaN.
    @ast.ArrayVal(xs) => str_to_number(arr_to_string(xs))
    @ast.ObjectVal(_) => nan()
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
  // Accumulate all digits as one integer, then divide by 10^k once:
  // a single correctly-rounded division, matching JS parseFloat
  // (double-rounding only matters past 15 significant digits).
  let mut acc = 0.0
  let mut digits = 0
  let mut frac = 0
  let mut saw_dot = false
  while i < n {
    let c = chars[i]
    if is_digit(c) {
      acc = acc * 10.0 + (c.to_int() - '0'.to_int()).to_double()
      digits += 1
      if saw_dot {
        frac += 1
      }
    } else if c == '.' && !saw_dot {
      saw_dot = true
    } else {
      return nan()
    }
    i += 1
  }
  if digits == 0 {
    return nan()
  }
  if saw_dot {
    let mut p10 = 1.0
    for _ in 0..<frac {
      p10 = p10 * 10.0
    }
    acc = acc / p10
  }
  if neg {
    -acc
  } else {
    acc
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
    @ast.IntVal(i) => i.to_string()
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
    // JS == against objects/arrays first coerces them via ToPrimitive.
    (@ast.ArrayVal(_) | @ast.ObjectVal(_), @ast.NumVal(y)) => to_number(a) == y
    (@ast.NumVal(x), @ast.ArrayVal(_) | @ast.ObjectVal(_)) => x == to_number(b)
    (@ast.ArrayVal(_) | @ast.ObjectVal(_), @ast.StrVal(y)) => to_string(a) == y
    (@ast.StrVal(x), @ast.ArrayVal(_) | @ast.ObjectVal(_)) => x == to_string(b)
    (_, _) => strict_eq(a, b)
  }
}

///|
/// JS relational comparison semantics for `< <= > >=`:
/// both strings → lexicographic; otherwise numeric with NaN → false.
pub fn compare(
  op : String,
  a : @ast.Value,
  b : @ast.Value,
) -> Bool raise EvalError {
  if typed_bin(a, b) {
    return typed_compare(op, a, b)
  }
  // JS relational semantics: operands go through ToPrimitive first.
  // Arrays become their joined string, objects "[object Object]".
  // When BOTH results are strings the comparison is lexicographic by
  // code unit; otherwise both sides coerce to numbers (NaN → false).
  if str_like(a) && str_like(b) {
    let c = lex_compare(to_string(a), to_string(b))
    match op {
      "<" => c < 0
      "<=" => c <= 0
      ">" => c > 0
      _ => c >= 0
    }
  } else {
    let x = to_number(a)
    let y = to_number(b)
    if x != x || y != y {
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

///|
/// Whether a value is string-like after JS ToPrimitive: strings stay,
/// arrays join, objects become "[object Object]".
fn str_like(v : @ast.Value) -> Bool {
  match v {
    @ast.StrVal(_) | @ast.ArrayVal(_) | @ast.ObjectVal(_) => true
    _ => false
  }
}

///|
/// Lexicographic comparison by code unit (JS String relational
/// semantics). Returns negative/zero/positive.
pub fn lex_compare(x : String, y : String) -> Int {
  let a = x.to_array()
  let b = y.to_array()
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return if ca < cb { -1 } else { 1 }
    }
  }
  if a.length() == b.length() {
    0
  } else if a.length() < b.length() {
    -1
  } else {
    1
  }
}

///|
/// JS remainder semantics (sign of dividend). MoonBit Double has no %,
/// so: a - trunc(a/b) * b.

///|
/// JS `%` — the IEEE fmod remainder (sign of the dividend, exact
/// residual). MoonBit has no fmod, so compute a - trunc(a/b)*b with
/// the product in double-double precision (Dekker splitting), which
/// avoids the double-rounding a naive Double multiply would cause.
pub fn remainder(a : Double, b : Double) -> Double {
  if b == 0.0 || a != a || b != b || a == 1.0 / 0.0 || a == -1.0 / 0.0 {
    return nan()
  }
  if a == 0.0 {
    return a
  }
  let q = a / b
  let trunc_q = if q < 0.0 { -(-q).floor() } else { q.floor() }
  let (p_hi, p_lo) = two_prod(trunc_q, b)
  let (s1, t1) = two_sum(a, -p_hi)
  let e = t1 - p_lo
  s1 + e
}

///|
/// Error-free transform of a product: p + err == x*y exactly
/// (Veltkamp/Dekker splitting, no FMA required).
fn two_prod(x : Double, y : Double) -> (Double, Double) {
  let p = x * y
  let c = 134217729.0 * x
  let x_hi = c - (c - x)
  let x_lo = x - x_hi
  let c2 = 134217729.0 * y
  let y_hi = c2 - (c2 - y)
  let y_lo = y - y_hi
  let err = x_hi * y_hi - p + x_hi * y_lo + x_lo * y_hi + x_lo * y_lo
  (p, err)
}

///|
/// Error-free transform of a sum: s + err == x + y exactly.
fn two_sum(x : Double, y : Double) -> (Double, Double) {
  let s = x + y
  let bb = s - x
  let err = x - (s - bb) + (y - bb)
  (s, err)
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

// --- Stage 4.4.3: typed (expr) semantics on IntVal-bearing operands ---
//
// The legacy Jexl path only ever produces NumVal (its lexer parses
// numbers as doubles), so "any operand is or contains an IntVal" is a
// sound runtime signal that expr's typed semantics apply. All numeric
// operators below keep the legacy JS behavior for pure-NumVal inputs.

///|
/// Whether a value is (or contains) a typed integer — the expr
/// dialect marker at runtime.
pub fn has_int(v : @ast.Value) -> Bool {
  match v {
    @ast.IntVal(_) => true
    @ast.ArrayVal(xs) => {
      for x in xs {
        if has_int(x) {
          return true
        }
      }
      false
    }
    @ast.ObjectVal(pairs) => {
      for kv in pairs {
        let (_, val) = kv
        if has_int(val) {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
fn typed_bin(a : @ast.Value, b : @ast.Value) -> Bool {
  has_int(a) || has_int(b)
}

///|
fn numeric_val(v : @ast.Value) -> Bool {
  match v {
    @ast.IntVal(_) | @ast.NumVal(_) => true
    _ => false
  }
}

///|
/// expr-style type name for error messages (Go type names).
fn typed_kind(v : @ast.Value) -> String {
  match v {
    @ast.IntVal(_) => "int"
    @ast.NumVal(_) => "float"
    @ast.BoolVal(_) => "bool"
    @ast.NullVal => "nil"
    @ast.UndefVal => "nil"
    @ast.StrVal(_) => "string"
    @ast.ArrayVal(_) => "array"
    @ast.ObjectVal(_) => "map"
  }
}

///|
fn typed_mismatch(op : String, a : @ast.Value, b : @ast.Value) -> EvalError {
  EvalError::EvalErr(
    "invalid operation: " + typed_kind(a) + " " + op + " " + typed_kind(b),
  )
}

///|
/// Typed equality (expr Eval-mode semantics): numerics promote
/// (int/int exact, int/float via float), anything else cross-kind is
/// false; containers compare structurally with strict element kinds.
pub fn typed_eq(a : @ast.Value, b : @ast.Value) -> Bool {
  match (a, b) {
    (@ast.IntVal(x), @ast.IntVal(y)) => x == y
    (@ast.IntVal(x), @ast.NumVal(y)) => x.to_double() == y
    (@ast.NumVal(x), @ast.IntVal(y)) => x == y.to_double()
    (@ast.IntVal(_), _) | (_, @ast.IntVal(_)) => false
    (_, _) => strict_eq(a, b)
  }
}

///|
/// Typed numeric comparison; other kind mixes raise (expr Eval-mode
/// panics "invalid operation: int < string").
pub fn typed_compare(
  op : String,
  a : @ast.Value,
  b : @ast.Value,
) -> Bool raise EvalError {
  if numeric_val(a) && numeric_val(b) {
    let r = match (a, b) {
      (@ast.IntVal(x), @ast.IntVal(y)) =>
        if x < y {
          -1
        } else if x > y {
          1
        } else {
          0
        }
      (_, _) => {
        let x = to_number(a)
        let y = to_number(b)
        if x != x || y != y {
          return false
        }
        if x < y {
          -1
        } else if x > y {
          1
        } else {
          0
        }
      }
    }
    match op {
      "<" => r < 0
      "<=" => r <= 0
      ">" => r > 0
      _ => r >= 0
    }
  } else {
    raise typed_mismatch(op, a, b)
  }
}

///|
/// Typed integer arithmetic entry used by the shared operators.
pub fn typed_int_arith(
  op : String,
  a : @ast.Value,
  b : @ast.Value,
) -> @ast.Value? {
  match (a, b) {
    (@ast.IntVal(x), @ast.IntVal(y)) =>
      match op {
        "+" => Some(@ast.IntVal(x + y))
        "-" => Some(@ast.IntVal(x - y))
        "*" => Some(@ast.IntVal(x * y))
        _ => None
      }
    (_, _) => None
  }
}
