// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — minimal time builtins.
//
// expr's now()/date() return Go time.Time objects with rich method
// sets; mbel's value model has no time type yet, so these return
// Unix-millisecond numbers in UTC. Timezone support is a cut item
// (docs/expr-gap-analysis.md §E.2): timezone() only accepts "UTC".

///|
fn time_functions() -> Array[(String, @evaluator.FnA)] {
  [
    ("now", fn(args) { @ast.NumVal(now_ms().to_double()) }),
    (
      "duration",
      fn(args) {
        let s = to_str(arg(args, 0, "duration"), "duration")
        match parse_duration(s) {
          Some(ns) => @ast.NumVal(ns.to_double())
          None => raise @evaluator.EvalErr("invalid duration: " + s)
        }
      },
    ),
    (
      "date",
      fn(args) {
        let s = to_str(arg(args, 0, "date"), "date")
        match parse_iso_date(s) {
          Some(ms) => @ast.NumVal(ms.to_double())
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
