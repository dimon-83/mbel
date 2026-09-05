// SPDX-License-Identifier: Apache-2.0
// mbel — concurrency-safety / memory-safety / stability tests.
//
// Concurrency model note: MoonBit's wasm-gc target is single-threaded
// and mbel's eval has no yield points, so every eval call is atomic —
// shared instances cannot observe torn state mid-evaluation. True
// host-level parallelism (workers) uses separate instances. These
// tests exercise the invariants that matter under such concurrent
// load: instance isolation, determinism, budget non-bypass, and
// graceful recovery after failures.

///|
test "instances are isolated (grammar + transforms)" {
  let a = @jexl.new_jexl()
  let b = @jexl.new_jexl()
  @jexl.Jexl::add_transform(a, "shout", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    match args[0] {
      @ast.StrVal(s) => @ast.StrVal(s + "!")
      other => other
    }
  })
  @jexl.Jexl::remove_op(a, "+")
  // a knows 'shout' and rejects '+'
  let ra = @jexl.Jexl::eval(a, "\"hey\"|shout", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("a shout failed: " + msg)
  }
  assert_true(@ast.value_equal(ra, @ast.StrVal("hey!")))
  try {
    ignore(@jexl.Jexl::eval(a, "1+2", v_obj([])))
    abort("a should reject + after remove_op")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  // b is untouched: no 'shout', '+' still works
  try {
    ignore(@jexl.Jexl::eval(b, "\"hey\"|shout", v_obj([])))
    abort("b should not know 'shout'")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  let rb = @jexl.Jexl::eval(b, "1+2", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("b plus failed: " + msg)
  }
  assert_true(@ast.value_equal(rb, v_num(3.0)))
}

///|
test "repeated evaluation is deterministic (500x)" {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(inst, "items[.qty > 2].name ?? 'none'") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let items : Array[@ast.Value] = []
  for i in 0..<20 {
    items.push(
      v_obj([
        ("name", @ast.StrVal("n" + i.to_string())),
        ("qty", v_num((i % 5).to_double())),
      ]),
    )
  }
  let ctx = v_obj([("items", @ast.ArrayVal(items))])
  let first = @jexl.Expression::eval(expr_obj, ctx) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  for _ in 0..<500 {
    let again = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort("nondeterministic: " + msg)
    }
    if !@ast.value_equal(first, again) {
      abort("repeated eval diverged")
    }
  }
}

///|
test "step budget cannot be bypassed by a large context array" {
  let inst = @jexl.new_jexl()
  // 100k-element context array; the filter predicate runs per element
  // and shares the parent's step budget (5k), so this must fail fast
  // instead of scanning the whole array.
  @jexl.Jexl::set_limits(inst, 0, 0, 5000)
  let big : Array[@ast.Value] = []
  for i in 0..<100000 {
    big.push(v_obj([("qty", v_num(i.to_double()))]))
  }
  let ctx = v_obj([("items", @ast.ArrayVal(big))])
  try {
    ignore(@jexl.Jexl::eval(inst, "items[.qty > 2]", ctx))
    abort("expected budget error on 100k filter")
  } catch {
    @jexl.JexlErr(msg) => assert_true(msg.contains("budget"))
  }
}

///|
test "engine stays usable after evaluation errors" {
  let inst = @jexl.new_jexl()
  // error 1: parse error
  try {
    ignore(@jexl.Jexl::eval(inst, "1 +", v_obj([])))
    abort("expected parse error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  // error 2: missing transform
  try {
    ignore(@jexl.Jexl::eval(inst, "\"x\"|nope", v_obj([])))
    abort("expected transform error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  // error 3: budget breach on a throwaway expression
  @jexl.Jexl::set_limits(inst, 0, 0, 5)
  try {
    ignore(
      @jexl.Jexl::eval(inst, "a+a+a+a+a+a+a+a+a+a", v_obj([("a", v_num(1.0))])),
    )
    abort("expected budget error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  // restore limits — the same instance still evaluates correctly
  @jexl.Jexl::set_limits(inst, 10000, 10000, 1000000)
  let r = @jexl.Jexl::eval(inst, "2 * 21", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("engine broken after errors: " + msg)
  }
  assert_true(@ast.value_equal(r, v_num(42.0)))
}

///|
test "interleaved evaluation across instances stays independent" {
  // Simulates concurrent load: alternating calls on two configured
  // instances (single-threaded wasm makes each call atomic).
  let a = @jexl.new_jexl()
  let b = @jexl.new_jexl()
  @jexl.Jexl::add_transform(a, "dbl", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(@evaluator.to_number(args[0]) * 2.0)
  })
  @jexl.Jexl::add_transform(b, "dbl", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(@evaluator.to_number(args[0]) * 3.0)
  })
  for i in 0..<200 {
    let ra = @jexl.Jexl::eval(a, "10|dbl", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    let rb = @jexl.Jexl::eval(b, "10|dbl", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    if !@ast.value_equal(ra, v_num(20.0)) || !@ast.value_equal(rb, v_num(30.0)) {
      abort("interleaved eval cross-contaminated at iteration " + i.to_string())
    }
  }
}

///|
test "deeply nested and large structures stay inside budgets" {
  let inst = @jexl.new_jexl()
  // deep nesting rejected gracefully (not a crash)
  let mut deep = "1"
  for _ in 0..<1500 {
    deep = "(" + deep + ")"
  }
  try {
    ignore(@jexl.Jexl::eval(inst, deep, v_obj([])))
    abort("expected nesting error")
  } catch {
    @jexl.JexlErr(msg) => assert_true(msg.contains("nested"))
  }
  // wide structures within budget work
  let mut wide = "0"
  for i in 1..<200 {
    wide = wide + "+" + i.to_string()
  }
  let r = @jexl.Jexl::eval(inst, wide, v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("wide expression failed: " + msg)
  }
  match r {
    @ast.NumVal(d) => assert_eq(d, 19900.0)
    _ => abort("expected number")
  }
}

///|
test "stab A: records[0].id" {
  let inst = @jexl.new_jexl()
  let items : Array[@ast.Value] = []
  for i in 0..<1000 {
    items.push(
      v_obj([
        ("id", v_num(i.to_double())),
        ("active", @ast.BoolVal(i % 2 == 0)),
        ("score", v_num((i % 100).to_double())),
      ]),
    )
  }
  let ctx = v_obj([("records", @ast.ArrayVal(items))])
  let err_cell : Array[String] = []
  let r = @jexl.Jexl::eval(inst, "records[0].id", ctx) catch {
    @jexl.JexlErr(msg) => {
      err_cell.push(msg)
      @ast.UndefVal
    }
  }
  assert_eq(err_cell.length(), 0)
  assert_true(@ast.value_equal(r, v_num(0.0)))
}

///|
test "stab B: records[.active] filter only" {
  let inst = @jexl.new_jexl()
  let items : Array[@ast.Value] = []
  for i in 0..<1000 {
    items.push(
      v_obj([
        ("id", v_num(i.to_double())),
        ("active", @ast.BoolVal(i % 2 == 0)),
        ("score", v_num((i % 100).to_double())),
      ]),
    )
  }
  let ctx = v_obj([("records", @ast.ArrayVal(items))])
  let err_cell : Array[String] = []
  let r = @jexl.Jexl::eval(inst, "records[.active]", ctx) catch {
    @jexl.JexlErr(msg) => {
      err_cell.push(msg)
      @ast.UndefVal
    }
  }
  assert_eq(err_cell.length(), 0)
  match r {
    @ast.ArrayVal(xs) => assert_eq(xs.length(), 500)
    _ => abort("expected array")
  }
}

///|
test "stab C: records[.active].score full" {
  let inst = @jexl.new_jexl()
  let items : Array[@ast.Value] = []
  for i in 0..<1000 {
    items.push(
      v_obj([
        ("id", v_num(i.to_double())),
        ("active", @ast.BoolVal(i % 2 == 0)),
        ("score", v_num((i % 100).to_double())),
      ]),
    )
  }
  let ctx = v_obj([("records", @ast.ArrayVal(items))])
  let err_cell : Array[String] = []
  let r = @jexl.Jexl::eval(inst, "records[.active].score", ctx) catch {
    @jexl.JexlErr(msg) => {
      err_cell.push(msg)
      @ast.UndefVal
    }
  }
  assert_eq(err_cell.length(), 0)
  // Jexl semantics: drilling into a filtered array takes element 0,
  // so the result is the first active record's score (0.0), not an
  // array (same as assoc[.first == "Lana"].last -> "Kane").
  assert_true(@ast.value_equal(r, v_num(0.0)))
}
