// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — math, string, collection, conversion, and
// time builtins. Semantics follow expr-lang's builtin.go where the
// value model allows; divergences are documented inline.

///|
fn arg(
  args : Array[@ast.Value],
  i : Int,
  name : String,
) -> @ast.Value raise @evaluator.EvalError {
  if i >= args.length() {
    raise @evaluator.EvalErr(name + ": missing argument " + i.to_string())
  }
  args[i]
}

// --- Math (expr: abs ceil floor round max min mean median) ---

///|
fn num(v : @ast.Value, name : String) -> Double raise @evaluator.EvalError {
  to_number_checked(v, name)
}

///|
fn to_number_checked(
  v : @ast.Value,
  name : String,
) -> Double raise @evaluator.EvalError {
  match v {
    @ast.NumVal(d) => d
    @ast.BoolVal(b) => if b { 1.0 } else { 0.0 }
    @ast.StrVal(s) =>
      match str_to_number_opt(s) {
        Some(d) => d
        None =>
          raise @evaluator.EvalErr(
            name + ": cannot convert " + s + " to number",
          )
      }
    _ => raise @evaluator.EvalErr(name + ": expected a number")
  }
}

///|
fn str_to_number_opt(s : String) -> Double? {
  let d = @evaluator.parse_decimal(s)
  if d != d {
    None
  } else {
    Some(d)
  }
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Go math.Round: half away from zero.
fn go_round(x : Double) -> Double {
  if x >= 0.0 {
    (x + 0.5).floor()
  } else {
    (x - 0.5).ceil()
  }
}

///|
/// Collects numbers from args; max/min/mean/median also accept arrays
/// of numbers (flattened one level, like expr's number collection).
fn collect_numbers(
  args : Array[@ast.Value],
  name : String,
) -> Array[Double] raise @evaluator.EvalError {
  let out : Array[Double] = []
  for a in args {
    match a {
      @ast.ArrayVal(xs) =>
        for x in xs {
          out.push(num(x, name))
        }
      other => out.push(num(other, name))
    }
  }
  out
}

// --- Collections (expr: len first last get take keys values reverse
// uniq concat flatten sort) ---

///|
fn value_len(v : @ast.Value) -> Int {
  match v {
    @ast.ArrayVal(xs) => xs.length()
    @ast.ObjectVal(pairs) => pairs.length()
    @ast.StrVal(s) => s.length()
    _ => 0
  }
}

///|
fn sort_values(xs : Array[@ast.Value]) -> Array[@ast.Value] {
  let mut all_str = true
  let mut all_num = true
  for x in xs {
    match x {
      @ast.StrVal(_) => all_num = false
      @ast.NumVal(_) => all_str = false
      _ => {
        all_str = false
        all_num = false
      }
    }
  }
  let out = xs.copy()
  if all_num {
    out.sort_by(fn(a, b) {
      match (a, b) {
        (@ast.NumVal(x), @ast.NumVal(y)) =>
          if x < y {
            -1
          } else if x > y {
            1
          } else {
            0
          }
        (_, _) => 0
      }
    })
  } else if all_str {
    out.sort_by(fn(a, b) {
      match (a, b) {
        (@ast.StrVal(x), @ast.StrVal(y)) => @evaluator.lex_compare(x, y)
        (_, _) => 0
      }
    })
  }
  // Mixed arrays have no total order in expr either; leave as-is.
  out
}

// --- Conversion (expr: int float string type toJSON fromJSON toPairs
// fromPairs; base64 in base64.mbt) ---

///|
/// Value → Json for toJSON. NaN/Infinity become null (JSON has no
/// representation; expr's Go marshal errors there).
fn value_to_json(v : @ast.Value) -> Json {
  match v {
    @ast.BoolVal(b) => Json::boolean(b)
    @ast.NumVal(d) =>
      if d != d || d == 1.0 / 0.0 || d == -1.0 / 0.0 {
        Json::null()
      } else {
        Json::number(d)
      }
    // note: int64 beyond 2^53 loses precision in JSON (expr emits the
    // exact digits) — documented divergence until a typed JSON writer
    @ast.IntVal(i) => Json::number(i.to_double())
    @ast.StrVal(s) => Json::string(s)
    @ast.NullVal | @ast.UndefVal => Json::null()
    @ast.ArrayVal(xs) => Json::array(xs.map(value_to_json))
    @ast.ObjectVal(pairs) => {
      let map = Map::from_iter(
        pairs
        .iter()
        .map(fn(kv) {
          let (k, val) = kv
          (k, value_to_json(val))
        }),
      )
      Json::object(map)
    }
  }
}

///|
/// Json → Value (shared with the CLI context parser).
pub fn json_to_value(j : Json) -> @ast.Value {
  match j {
    Null => @ast.NullVal
    True => @ast.BoolVal(true)
    False => @ast.BoolVal(false)
    Number(d, ..) => @ast.NumVal(d)
    String(s) => @ast.StrVal(s)
    Array(xs) => @ast.ArrayVal(xs.map(json_to_value))
    Object(m) => {
      let pairs = m
        .to_array()
        .map(fn(kv) {
          let (k, v) = kv
          (k, json_to_value(v))
        })
      @ast.ObjectVal(pairs)
    }
  }
}

// --- Time (minimal subset; expr's time.Time objects, layouts beyond
// ISO 8601, and timezone databases are cut items — see
// docs/expr-gap-analysis.md) ---

///|
/// Unix time in milliseconds (UTC).
pub fn now_ms() -> Int64 {
  @env.now().to_int64()
}

///|
/// Parses Go-style durations: sequences like "1h30m", "250ms",
/// "1.5h", "2us", units ns us µs ms s m h. Returns nanoseconds.
pub fn parse_duration(s : String) -> Int64? {
  let chars = s.to_array()
  let n = chars.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut total = 0L
  if chars[i] == '-' {
    // expr durations are non-negative; treat '-' as invalid
    return None
  }
  while i < n {
    // number part (optional fraction)
    let start = i
    let mut saw_digit = false
    let mut saw_dot = false
    while i < n {
      let c = chars[i]
      if is_digit(c) {
        saw_digit = true
        i += 1
      } else if c == '.' && !saw_dot {
        saw_dot = true
        i += 1
      } else {
        break
      }
    }
    if !saw_digit {
      return None
    }
    let num_str = s[start:i].to_owned()
    let value = @evaluator.parse_decimal(num_str)
    if value != value {
      return None
    }
    // unit
    let unit_start = i
    while i < n && !is_digit(chars[i]) && chars[i] != '.' {
      i += 1
    }
    let unit = s[unit_start:i].to_owned()
    let factor_ns : Int64 = match unit {
      "ns" => 1L
      "us" | "µs" => 1000L
      "ms" => 1000000L
      "s" => 1000000000L
      "m" => 60000000000L
      "h" => 3600000000000L
      _ => return None
    }
    total = total + (value * factor_ns.to_double()).to_int64()
  }
  Some(total)
}

///|
/// Days from civil date (Howard Hinnant's algorithm) — days since
/// 1970-01-01 for a proleptic Gregorian date.
fn days_from_civil(y : Int, m : Int, d : Int) -> Int64 {
  let y2 = if m <= 2 { y - 1 } else { y }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let mp = (m + 9) % 12
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.to_int64() * 146097L + doe.to_int64() - 719468L
}

///|
/// Parses ISO 8601 dates: "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SS"
/// (optional fractional seconds and trailing 'Z'). Returns Unix ms.
pub fn parse_iso_date(s : String) -> Int64? {
  let chars = s.to_array()
  let n = chars.length()
  if n < 10 {
    return None
  }
  let digits_of = fn(a : Array[Char], from : Int, len : Int) -> Int? {
    let mut v = 0
    for k in 0..<len {
      let c = a[from + k]
      if !is_digit(c) {
        return None
      }
      v = v * 10 + (c.to_int() - '0'.to_int())
    }
    Some(v)
  }
  let y = match digits_of(chars, 0, 4) {
    Some(v) => v
    None => return None
  }
  if chars[4] != '-' {
    return None
  }
  let mth = match digits_of(chars, 5, 2) {
    Some(v) => v
    None => return None
  }
  if chars[7] != '-' {
    return None
  }
  let d = match digits_of(chars, 8, 2) {
    Some(v) => v
    None => return None
  }
  if mth < 1 || mth > 12 || d < 1 || d > 31 {
    return None
  }
  let mut ms = days_from_civil(y, mth, d) * 86400000L
  if n > 10 {
    // T or space separator
    if chars[10] != 'T' && chars[10] != ' ' {
      return None
    }
    if n < 19 {
      return None
    }
    let hh = match digits_of(chars, 11, 2) {
      Some(v) => v
      None => return None
    }
    if chars[13] != ':' {
      return None
    }
    let mm = match digits_of(chars, 14, 2) {
      Some(v) => v
      None => return None
    }
    if chars[16] != ':' {
      return None
    }
    let ss = match digits_of(chars, 17, 2) {
      Some(v) => v
      None => return None
    }
    if hh > 23 || mm > 59 || ss > 60 {
      return None
    }
    ms = ms + (hh * 3600000 + mm * 60000 + ss * 1000).to_int64()
  }
  Some(ms)
}
