// SPDX-License-Identifier: Apache-2.0
// expr's time builtin call forms, locked on both engines.
//
// expr's date() takes an optional *time.Location first, then the date
// string, an optional Go layout, and an optional zone name. mbel's only
// location value is the string timezone() returns, so a known location name
// in the first position is read as one. A numeric offset is applied where
// expr applies it — inside the date string (RFC3339) — because
// timezone("+08:00") is an error in Go as well.

///|
fn time_forms_err(src : String, label : String) -> Unit {
  for mode in [@engine.Walk, @engine.Vm] {
    let inst = @engine.new()
    @engine.Engine::set_engine(inst, mode)
    let got : String = try {
      ignore(@engine.Engine::eval_expr(inst, src, @ast.ObjectVal([])))
      "no error"
    } catch {
      @engine.EngineErr(msg) => msg
    }
    if got == "no error" {
      abort(label + ": expected an error")
    }
  }
}

///|
test "time: timezone() accepts only what mbel can represent" {
  expect_expr_both("timezone(\"UTC\")", @ast.StrVal("UTC"), "UTC")
  expect_expr_both("timezone(\"\")", @ast.StrVal("UTC"), "empty is UTC")
  // Go rejects a numeric offset here too: time.LoadLocation("+08:00") is
  // "unknown time zone +08:00".
  time_forms_err("timezone(\"+08:00\")", "offset rejected like Go")
  time_forms_err("timezone(\"Asia/Shanghai\")", "IANA needs the zone database")
  time_forms_err("timezone(\"Local\")", "host zone needs FFI")
}

///|
test "time: date() call forms" {
  let midnight : @ast.Value = @ast.IntVal(1704067200000000000L)
  // The location may come first (expr's order) or last.
  expect_expr_both("date(timezone(\"UTC\"), \"2024-01-01\")", midnight, "tz first")
  expect_expr_both(
    "date(timezone(\"UTC\"), \"2024-01-01\", \"2006-01-02\")", midnight, "tz first + layout",
  )
  expect_expr_both(
    "date(\"2024-01-01\", \"2006-01-02\", \"UTC\")", midnight, "tz last",
  )
  // A caller-supplied layout, including Go's 1-digit forms.
  expect_expr_both("date(\"2024-01-01\", \"2006-01-02\")", midnight, "explicit layout")
  expect_expr_both("date(\"2024-1-1\", \"2006-1-2\")", midnight, "1-digit layout")
  // 02/01/2006 is day/month/year, so this is 2024-02-01 (value from Go).
  expect_expr_both(
    "date(\"01/02/2024\", \"02/01/2006\")",
    @ast.IntVal(1706745600000000000L),
    "slash layout (day/month/year)",
  )
  // Offsets: expr applies the numeric zone inside the string.
  expect_expr_both(
    "date(\"2024-01-01T00:00:00+08:00\")",
    @ast.IntVal(1704038400000000000L),
    "RFC3339 offset",
  )
  expect_expr_both(
    "date(\"2024-01-01T00:00:00.5+08:00\")",
    @ast.IntVal(1704038400500000000L),
    "offset + fraction",
  )
  expect_expr_both(
    "date(\"01 Jan 24 15:04 UTC\")", @ast.IntVal(1704121440000000000L), "RFC822",
  )
  expect_expr_both(
    "date(\"Monday, 02-Jan-06 15:04:05 UTC\")",
    @ast.IntVal(1136214245000000000L),
    "RFC850",
  )
  expect_expr_both(
    "date(\"Mon, 02 Jan 2006 15:04:05 UTC\")",
    @ast.IntVal(1136214245000000000L),
    "RFC1123",
  )
  // Rejected inputs stay rejected: a mismatched weekday, an out-of-range
  // day, an unknown zone name, and a bad arity.
  time_forms_err("date(\"Monday, 02-Jan-06 15:04:05 UTC\", \"2006-01-02\")", "bad combo")
  time_forms_err("date(\"2023-02-29\")", "not a leap year")
  time_forms_err("date(\"2024-13-01\")", "month out of range")
  time_forms_err("date(\"2024/01/01\")", "not one of expr's layouts")
  time_forms_err("date(\"2024-01-01\", \"2006-01-02\", \"Asia/Shanghai\")", "unknown zone")
  time_forms_err("date()", "no arguments")
}

///|
test "time: now() shares the instant across locations" {
  // now(tz) is the same instant in a location, and an int64 nanosecond
  // count is location-free, so the argument only has to be valid.
  let a = @engine.Engine::eval_expr(@engine.new(), "now()", @ast.ObjectVal([])) catch {
    @engine.EngineErr(msg) => abort(msg)
  }
  let b = @engine.Engine::eval_expr(
    @engine.new(), "now(timezone(\"UTC\"))", @ast.ObjectVal([]),
  ) catch {
    @engine.EngineErr(msg) => abort(msg)
  }
  match (a, b) {
    (@ast.IntVal(x), @ast.IntVal(y)) => {
      if y < x {
        abort("now(tz) went backwards")
      }
      // A second is far more than the gap between two calls.
      if y - x > 1000000000L {
        abort("now(tz) is not the same instant")
      }
    }
    _ => abort("now() must be an int64 nanosecond count")
  }
  time_forms_err("now(\"Asia/Shanghai\")", "unknown zone")
}
