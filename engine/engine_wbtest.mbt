// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the resource-guard state that is not visible from
// outside the package: the compiled `matches` pattern caches and their
// capacity bound.

///|
fn wb_match(inst : Engine, subject : String, pattern : String) -> Unit {
  let ctx = @ast.ObjectVal([
    ("s", @ast.StrVal(subject)),
    ("p", @ast.StrVal(pattern)),
  ])
  ignore(try? Engine::eval_expr(inst, "s matches p", ctx))
}

///|
test "compiled pattern cache is capacity bounded" {
  let inst = new()
  let cap = @evaluator.regex_cache_capacity()
  // Three times as many distinct patterns as the cache may hold.
  for i in 0..<(cap * 3) {
    wb_match(inst, "x", "p" + i.to_string())
  }
  assert_true(inst.grammar.regex_cache.length() <= cap)
  assert_true(inst.grammar.regex_cache.length() > 0)
  // Every pattern was valid, so nothing landed in the failure cache.
  assert_eq(inst.grammar.regex_failed.length(), 0)
}

///|
test "failed pattern cache is capacity bounded" {
  let inst = new()
  let cap = @evaluator.regex_failed_capacity()
  for i in 0..<(cap * 3) {
    // Unterminated class: always a cut, never compiled.
    wb_match(inst, "x", "[" + i.to_string())
  }
  assert_true(inst.grammar.regex_failed.length() <= cap)
  assert_eq(inst.grammar.regex_cache.length(), 0)
}

///|
test "clear_caches empties both caches and later matches still work" {
  let inst = new()
  let ctx : @ast.Value = @ast.ObjectVal([
    ("s", @ast.StrVal("hello")),
    ("p", @ast.StrVal("^h.*o$")),
  ])
  let first = Engine::eval_expr(inst, "s matches p", ctx) catch {
    EngineErr(msg) => abort("match before clearing failed: " + msg)
  }
  assert_true(@ast.value_equal(first, @ast.BoolVal(true)))
  wb_match(inst, "x", "[")
  assert_true(inst.grammar.regex_cache.length() > 0)
  assert_true(inst.grammar.regex_failed.length() > 0)
  Engine::clear_caches(inst)
  assert_eq(inst.grammar.regex_cache.length(), 0)
  assert_eq(inst.grammar.regex_failed.length(), 0)
  // Recompiles from scratch rather than failing.
  let second = Engine::eval_expr(inst, "s matches p", ctx) catch {
    EngineErr(msg) => abort("match after clearing failed: " + msg)
  }
  assert_true(@ast.value_equal(second, @ast.BoolVal(true)))
}
