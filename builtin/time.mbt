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
// Timezone support is a cut item (docs/expr-gap-analysis.md §E.2):
// timezone() only accepts "UTC". Dates beyond 2262-04-11 overflow int64
// nanoseconds, the same limit Go's UnixNano has.

///|
/// The layouts expr's `date(string)` tries, in expr's order.
fn go_date_layouts() -> Array[String] {
  [
    "2006-01-02",
    "15:04:05",
    "2006-01-02 15:04:05",
    // time.RFC3339
    "2006-01-02T15:04:05Z07:00",
    // time.RFC822, time.RFC850, time.RFC1123
    "02 Jan 06 15:04 MST",
    "Monday, 02-Jan-06 15:04:05 MST",
    "Mon, 02 Jan 2006 15:04:05 MST",
  ]
}

///|
/// mbel's location values are the strings `timezone()` produces; the IANA
/// database is a documented cut, so only UTC and "" resolve.
fn location_name(v : @ast.Value) -> String raise @evaluator.EvalError {
  let name = to_str(v, "timezone")
  if name == "UTC" || name == "" {
    "UTC"
  } else {
    raise @evaluator.EvalErr("unknown time zone " + name)
  }
}

///|
fn is_location(v : @ast.Value) -> Bool {
  match v {
    @ast.StrVal(s) => s == "UTC" || s == ""
    _ => false
  }
}

///|
/// expr's `date`: an optional location first, then the date string, then an
/// optional layout, then an optional zone name. Only a location mbel can
/// represent is accepted; a numeric offset inside the string is applied
/// (that is where expr supports fixed offsets — `timezone("+08:00")` is an
/// error in Go too).
fn date_value(args : Array[@ast.Value]) -> @ast.Value raise @evaluator.EvalError {
  let n = args.length()
  if n == 0 {
    raise @evaluator.EvalErr(
      "invalid number of arguments (expected at least 1, got 0)",
    )
  }
  let mut idx = 0
  if n >= 2 && is_location(args[0]) {
    ignore(location_name(args[0]))
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
    ignore(location_name(arg(args, idx + 2, "date")))
  }
  match layout {
    Some(l) =>
      match go_parse_layout(src, l) {
        Some(ns) => @ast.IntVal(ns)
        None => raise @evaluator.EvalErr("invalid date: " + src)
      }
    None => {
      for l in go_date_layouts() {
        match go_parse_layout(src, l) {
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
          ignore(location_name(arg(args, 0, "now")))
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
    ("timezone", fn(args) { @ast.StrVal(location_name(arg(args, 0, "timezone"))) }),
  ]
}
