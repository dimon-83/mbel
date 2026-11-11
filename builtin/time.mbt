// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — minimal time builtins.
//
// expr's now()/date() return Go time.Time objects with rich method
// sets; mbel's value model has no time type yet, so these return
// **int64 nanoseconds since the Unix epoch, in UTC** — the same unit as
// `duration()` and as Go's `time.Time.UnixNano` / `time.Duration`.
//
// One unit throughout is the point: with time in milliseconds and
// duration in nanoseconds, `date(...) + duration("24h")` silently added
// ms to ns and produced a meaningless number. int64 (not double) is the
// other half: nanoseconds since the epoch exceed 2^53, so a double
// representation would make timestamps < ~256 ns apart compare equal.
//
// Timezone support is a fixed-offset IANA subset: timezone() resolves
// UTC and the zones in fixed_offset_zones() below; the full tzdata
// database remains a documented cut (docs/expr-gap-analysis.md §E.2),
// so dates in a zone's historical DST era diverge from Go. Dates beyond
// 2262-04-11 overflow int64 nanoseconds, the same limit Go's UnixNano
// has.

///|
/// The layouts expr's `date(string)` tries, in expr's order.
fn go_date_layouts() -> Array[String] {
  [
    "2006-01-02", "15:04:05", "2006-01-02 15:04:05",
    // time.RFC3339
     "2006-01-02T15:04:05Z07:00",
    // time.RFC822, time.RFC850, time.RFC1123
     "02 Jan 06 15:04 MST", "Monday, 02-Jan-06 15:04:05 MST", "Mon, 02 Jan 2006 15:04:05 MST",
  ]
}

///|
/// The fixed-offset IANA zone subset mbel resolves without shipping the
/// tzdata database: zones whose offset has been constant for decades
/// (no DST in the modern era). Offsets are minutes east of UTC. Dates
/// before a zone's last DST transition (Asia/Shanghai ran DST in
/// 1986-1991, Hong Kong and Taipei until 1979) diverge from Go's
/// tzdata-based result — a bounded, documented divergence.
fn fixed_offset_zones() -> Array[(String, Int32)] {
  [
    ("UTC", 0),
    ("Etc/UTC", 0),
    ("Asia/Shanghai", 480),
    ("Asia/Chongqing", 480),
    ("Asia/Harbin", 480),
    ("Asia/Hong_Kong", 480),
    ("Asia/Macau", 480),
    ("Asia/Taipei", 480),
    ("Asia/Singapore", 480),
    ("Asia/Tokyo", 540),
    ("Asia/Seoul", 540),
  ]
}

///|
/// mbel's location values are the strings `timezone()` produces: "UTC",
/// the empty string, and the fixed-offset IANA subset above. Returns
/// the canonical zone name and its offset in minutes east of UTC; an
/// unknown name raises Go's `time.LoadLocation` wording.
fn resolve_location(
  v : @ast.Value,
) -> (String, Int32) raise @evaluator.EvalError {
  let name = to_str(v, "timezone")
  if name == "" {
    return ("UTC", 0)
  }
  for zone in fixed_offset_zones() {
    if zone.0 == name {
      return zone
    }
  }
  raise @evaluator.EvalErr("unknown time zone " + name)
}

///|
fn is_location(v : @ast.Value) -> Bool {
  match v {
    @ast.StrVal(s) => {
      if s == "" {
        return true
      }
      for zone in fixed_offset_zones() {
        if zone.0 == s {
          return true
        }
      }
      false
    }
    _ => false
  }
}

///|
/// expr's `date`: an optional location first, then the date string, then an
/// optional layout, then an optional zone name. The location's offset is
/// the default the wall-clock fields are read in (Go's ParseInLocation);
/// a numeric offset inside the string overrides it, as in Go.
/// `timezone("+08:00")` stays an error, exactly like Go's
/// `time.LoadLocation("+08:00")`.
fn date_value(
  args : Array[@ast.Value],
) -> @ast.Value raise @evaluator.EvalError {
  let n = args.length()
  if n == 0 {
    raise @evaluator.EvalErr(
      "invalid number of arguments (expected at least 1, got 0)",
    )
  }
  let mut idx = 0
  let mut default_offset = 0
  if n >= 2 && is_location(args[0]) {
    let (_, off) = resolve_location(args[0])
    default_offset = off
    idx = 1
  }
  let src = to_str(arg(args, idx, "date"), "date")
  let rest = n - idx
  if rest > 3 {
    raise @evaluator.EvalErr(
      "invalid number of arguments (expected at most 3, got " +
      rest.to_string() +
      ")",
    )
  }
  let layout : String? = if rest >= 2 {
    Some(to_str(arg(args, idx + 1, "date"), "date"))
  } else {
    None
  }
  if rest >= 3 {
    let (_, off) = resolve_location(arg(args, idx + 2, "date"))
    default_offset = off
  }
  match layout {
    Some(l) =>
      match go_parse_layout(src, l, default_offset) {
        Some(ns) => @ast.IntVal(ns)
        None => raise @evaluator.EvalErr("invalid date: " + src)
      }
    None => {
      for l in go_date_layouts() {
        match go_parse_layout(src, l, default_offset) {
          Some(ns) => return @ast.IntVal(ns)
          None => ()
        }
      }
      raise @evaluator.EvalErr("invalid date: " + src)
    }
  }
}

///|
fn time_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "now",
      // expr's now(tz) is the same instant expressed in a location; an
      // instant in nanoseconds is location-free, so only the argument's
      // validity matters.
      fn(args) {
        if args.length() == 1 {
          ignore(resolve_location(arg(args, 0, "now")))
        }
        @ast.IntVal(now_ns())
      },
    ),
    (
      "duration",
      fn(args) {
        let s = to_str(arg(args, 0, "duration"), "duration")
        match parse_duration(s) {
          Some(ns) => @ast.IntVal(ns)
          None => raise @evaluator.EvalErr("invalid duration: " + s)
        }
      },
    ),
    ("date", fn(args) { date_value(args) }),
    (
      "timezone",
      fn(args) {
        let (name, _) = resolve_location(arg(args, 0, "timezone"))
        @ast.StrVal(name)
      },
    ),
  ]
}
