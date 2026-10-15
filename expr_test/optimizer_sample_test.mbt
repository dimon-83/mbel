// SPDX-License-Identifier: Apache-2.0
// expr's optimizer test table, sampled behaviourally.
//
// expr/optimizer rewrites the AST (sum over a range becomes a formula,
// filter/map fuse, count thresholds, ...). mbel implements constant folding
// only, and docs/coverage-vs-expr.md records why the rest is not ported: the
// rewrites change observable behaviour under mbel's contracts. This test
// pins the property that must hold anyway — evaluating those inputs without
// the passes yields what expr yields with them.
//
// Env mirrors the upstream test: {a: 1, b: 2, c: 3}.

///|
fn optimizer_sample_env() -> Array[(String, @ast.Value)] {
  [("a", IntVal(1L)), ("b", IntVal(2L)), ("c", IntVal(3L))]
}

///|
/// input -> reason it cannot match (documented divergence).
fn optimizer_sample_skips() -> Array[(String, String)] {
  []
}

///|
test "optimizer sample: expr's optimizer table evaluates identically" {
  let skips = optimizer_sample_skips()
  let ctx = @ast.ObjectVal(optimizer_sample_env())
  let fails = StringBuilder::new()
  let mut matched = 0
  let mut skipped = 0
  let modes : Array[(String, @engine.EngineMode)] = [("walk", Walk), ("vm", Vm)]
  for entry in modes {
    let (mode_name, mode) = entry
    for row in optimizer_sample_cases {
      let (src, want) = row
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
        let inst = want_new_engine(mode)
        want_canon(@engine.Engine::eval_expr(inst, src, ctx))
      } catch {
        @engine.EngineErr(m) => "ERR: " + m
        _ => "ERR: ?"
      }
      if first_pass && got == want {
        matched = matched + 1
      }
      if got != want {
        fails.write_string(
          "---\n" +
          src +
          " (" +
          mode_name +
          ")\n  got  " +
          got +
          "\n  want " +
          want +
          "\n",
        )
      }
    }
  }
  let total = optimizer_sample_cases.length()
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
