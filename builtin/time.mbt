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
fn time_functions() -> Array[(String, @evaluator.FnA)] {
  [
    ("now", fn(args) { @ast.IntVal(now_ns()) }),
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
    (
      "date",
      fn(args) {
        let s = to_str(arg(args, 0, "date"), "date")
        match parse_iso_date(s) {
          // parse_iso_date yields milliseconds; time values are ns.
          Some(ms) => @ast.IntVal(ms * 1000000L)
          None => raise @evaluator.EvalErr("invalid date: " + s)
        }
      },
    ),
    (
      "timezone",
      fn(args) {
        let name = to_str(arg(args, 0, "timezone"), "timezone")
        if name == "UTC" || name == "" {
          @ast.StrVal("UTC")
        } else {
          raise @evaluator.EvalErr("unknown time zone " + name)
        }
      },
    ),
  ]
}
