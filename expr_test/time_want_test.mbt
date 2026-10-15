// SPDX-License-Identifier: Apache-2.0
// date() alignment against expr, via Go's own time.Parse.
//
// expr's date(string) scans seven Go reference layouts; the expected column
// here is produced by running exactly that scan in Go (tools/time_oracle),
// so agreement is against the reference implementation rather than against
// a re-reading of it. The rows include RFC3339 numeric offsets, which is
// where expr supports fixed offsets — `timezone("+08:00")` is an error in
// Go as well, so mbel keeps rejecting it.

///|
/// input -> reason it cannot match (documented divergence).
fn time_want_skips() -> Array[(String, String)] {
  []
}

///|
test "time: expr date() results" {
  let skips = time_want_skips()
  let ctx = @ast.ObjectVal([])
  let fails = StringBuilder::new()
  let mut matched = 0
  let mut skipped = 0
  let modes : Array[(String, @engine.EngineMode)] = [("walk", Walk), ("vm", Vm)]
  for mode in modes {
    let (mode_name, m) = mode
    for row in time_want_cases {
      let (src, want) = row
      let src_q = "\"" + src + "\""
      let mut reason = ""
      for s in skips {
        let (s_src, s_reason) = s
        if s_src == src {
          reason = s_reason
        }
      }
      let first_pass = mode_name == "walk"
      if first_pass && reason != "" {
        skipped = skipped + 1
        continue
      }
      let got : String = try {
        let inst = @engine.new()
        @engine.Engine::set_engine(inst, m)
        @evaluator.to_string(
          @engine.Engine::eval_expr(inst, "date(" + src_q + ")", ctx),
        )
      } catch {
        @engine.EngineErr(_) => "ERR"
        _ => "ERR"
      }
      if first_pass && got == want {
        matched = matched + 1
      }
      if got != want {
        fails.write_string(
          "---\n" + src + " (" + mode_name + ")\n  got  " + got + "\n  want " + want + "\n",
        )
      }
    }
  }
  let total = time_want_cases.length()
  let summary = (
    "matched " +
    matched.to_string() +
    "/" +
    total.to_string() +
    " (skipped " +
    skipped.to_string() +
    ")\n" +
    fails.to_string()
  )
  if matched + skipped != total {
    inspect(summary, content="")
  }
}
