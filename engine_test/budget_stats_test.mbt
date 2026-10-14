// SPDX-License-Identifier: Apache-2.0
// Resource-gate observability. The budget *messages* are contract-locked
// (AGENTS.md), so `Engine::budget_stats` is the only surface that tells
// an embedder the gate fired, how often, and for which reason.

///|
fn stats_of(inst : @engine.Engine) -> Array[(String, Int)] {
  @engine.Engine::budget_stats(inst)
}

///|
test "budget stats count gate violations by reason" {
  let inst = @engine.new()
  assert_eq(stats_of(inst).length(), 0)

  // Depth: a 60-level identifier chain against a 50-level ceiling.
  @engine.Engine::set_limits(inst, 0, 50, 0)
  let deep = repeat_str("a.", 60) + "b"
  ignore(try? @engine.Engine::eval(inst, deep, @ast.ObjectVal([])))
  let s1 = stats_of(inst)
  assert_eq(s1.length(), 1)
  assert_eq(s1[0], ("depth", 1))

  // Tripping the same gate again increments rather than duplicating.
  ignore(try? @engine.Engine::eval(inst, deep, @ast.ObjectVal([])))
  assert_eq(stats_of(inst)[0], ("depth", 2))

  // The node budget reports its own reason.
  @engine.Engine::set_limits(inst, 100, 0, 0)
  ignore(
    try? @engine.Engine::eval(inst, repeat_str("1+", 200) + "1", @ast.ObjectVal([])),
  )
  let s2 = stats_of(inst)
  assert_eq(s2.length(), 2)
  assert_eq(s2[1], ("nodes", 1))

  // Ordinary errors are not resource-gate events.
  ignore(try? @engine.Engine::eval(inst, "1 +", @ast.ObjectVal([])))
  ignore(try? @engine.Engine::eval(inst, "1 + \"a\"", @ast.ObjectVal([])))
  assert_eq(stats_of(inst).length(), 2)

  @engine.Engine::reset_budget_stats(inst)
  assert_eq(stats_of(inst).length(), 0)
}

///|
test "budget stats cover the expr front-end path without double counting" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 50, 0)
  let deep = repeat_str("a.", 60) + "b"
  ignore(try? @engine.Engine::eval_expr(inst, deep, @ast.ObjectVal([])))
  // One violation, not two: the parse and eval stages have separate
  // guards and the depth failure belongs to the eval stage only.
  let stats = stats_of(inst)
  assert_eq(stats.length(), 1)
  assert_eq(stats[0], ("depth", 1))

  // The strict entry shares the same eval-stage guard.
  ignore(try? @engine.Engine::eval_expr_checked(inst, deep, @ast.ObjectVal([])))
  assert_eq(stats_of(inst)[0], ("depth", 2))
}

///|
test "memory budget has its own reason" {
  let inst = @engine.new()
  // A range longer than expr's 1e6-element memory budget.
  ignore(try? @engine.Engine::eval_expr(inst, "0..2000000", @ast.ObjectVal([])))
  let stats = stats_of(inst)
  assert_eq(stats.length(), 1)
  assert_eq(stats[0], ("memory", 1))
}

///|
test "budget stats is a copy, not live engine state" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 50, 0)
  let deep = repeat_str("a.", 60) + "b"
  ignore(try? @engine.Engine::eval(inst, deep, @ast.ObjectVal([])))
  let snapshot = stats_of(inst)
  assert_eq(snapshot.length(), 1)
  ignore(try? @engine.Engine::eval(inst, deep, @ast.ObjectVal([])))
  // The earlier snapshot is unaffected by the later violation.
  assert_eq(snapshot[0], ("depth", 1))
  assert_eq(stats_of(inst)[0], ("depth", 2))
}
