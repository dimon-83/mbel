// SPDX-License-Identifier: Apache-2.0
// mbel — stability / memory-safety suite, run on BOTH engines.
//
// Concurrency model note: MoonBit's wasm-gc target is single-threaded
// and neither engine yields mid-evaluation, so every eval call is
// atomic. Host-level parallelism uses separate instances. This suite
// exercises the invariants that matter under such concurrent load —
// instance isolation, determinism, budget non-bypass, recovery after
// failures — once per engine, with identical assertions, so any
// engine-specific instability shows up as an asymmetric failure.

///|
/// Runs the full stability suite on the given engine. All assertions
/// are engine-independent; the walk suite doubles as the reference.
fn stability_suite(vm : Bool) -> Unit raise {
  let inst = @jexl.new_jexl()
  if vm {
    @jexl.Jexl::set_engine(inst, Vm)
  }
  let v_num = fn(d : Double) -> @ast.Value { @ast.NumVal(d) }
  let v_obj = fn(pairs : Array[(String, @ast.Value)]) -> @ast.Value {
    @ast.ObjectVal(pairs)
  }

  // 1. Instance isolation: a's grammar/transform changes never leak.
  let a = @jexl.new_jexl()
  if vm {
    @jexl.Jexl::set_engine(a, Vm)
  }
  let b = @jexl.new_jexl()
  if vm {
    @jexl.Jexl::set_engine(b, Vm)
  }
  @jexl.Jexl::add_transform(a, "shout", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    match args[0] {
      @ast.StrVal(s) => @ast.StrVal(s + "!")
      other => other
    }
  })
  @jexl.Jexl::remove_op(a, "+")
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

  // 2. Determinism: 500 repeated evaluations of a compiled expression.
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

  // 3. Budget non-bypass: a 100k-element context array cannot scan
  //    past the shared step budget.
  let budgeted = @jexl.new_jexl()
  if vm {
    @jexl.Jexl::set_engine(budgeted, Vm)
  }
  @jexl.Jexl::set_limits(budgeted, 0, 0, 5000)
  let big : Array[@ast.Value] = []
  for i in 0..<100000 {
    big.push(v_obj([("qty", v_num(i.to_double()))]))
  }
  let big_ctx = v_obj([("items", @ast.ArrayVal(big))])
  try {
    ignore(@jexl.Jexl::eval(budgeted, "items[.qty > 2]", big_ctx))
    abort("expected budget error on 100k filter")
  } catch {
    @jexl.JexlErr(msg) => assert_true(msg.contains("budget"))
  }

  // 4. Engine stays usable after parse / transform / budget failures.
  try {
    ignore(@jexl.Jexl::eval(inst, "1 +", v_obj([])))
    abort("expected parse error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  try {
    ignore(@jexl.Jexl::eval(inst, "\"x\"|nope", v_obj([])))
    abort("expected transform error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  @jexl.Jexl::set_limits(inst, 0, 0, 5)
  try {
    ignore(@jexl.Jexl::eval(inst, "[1]+[1]+[1]+[1]+[1]+[1]", v_obj([])))
    abort("expected budget error")
  } catch {
    @jexl.JexlErr(_) => ()
  }
  @jexl.Jexl::set_limits(inst, 10000, 10000, 1000000)
  let r4 = @jexl.Jexl::eval(inst, "2 * 21", v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("engine broken after errors: " + msg)
  }
  assert_true(@ast.value_equal(r4, v_num(42.0)))

  // 5. Interleaved evaluation across configured instances.
  let ia = @jexl.new_jexl()
  let ib = @jexl.new_jexl()
  if vm {
    @jexl.Jexl::set_engine(ia, Vm)
    @jexl.Jexl::set_engine(ib, Vm)
  }
  @jexl.Jexl::add_transform(ia, "dbl", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(@evaluator.to_number(args[0]) * 2.0)
  })
  @jexl.Jexl::add_transform(ib, "dbl", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    v_num(@evaluator.to_number(args[0]) * 3.0)
  })
  for i in 0..<200 {
    let ra2 = @jexl.Jexl::eval(ia, "10|dbl", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    let rb2 = @jexl.Jexl::eval(ib, "10|dbl", v_obj([])) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    if !@ast.value_equal(ra2, v_num(20.0)) ||
      !@ast.value_equal(rb2, v_num(30.0)) {
      abort("interleaved eval cross-contaminated at " + i.to_string())
    }
  }

  // 6. Nesting budget rejects gracefully (parser-level, engine-agnostic
  //    but asserted per engine for completeness).
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
  let mut wide = "0"
  for i in 1..<200 {
    wide = wide + "+" + i.to_string()
  }
  let r6 = @jexl.Jexl::eval(inst, wide, v_obj([])) catch {
    @jexl.JexlErr(msg) => abort("wide expression failed: " + msg)
  }
  match r6 {
    @ast.NumVal(d) => assert_eq(d, 19900.0)
    _ => abort("expected number")
  }

  // 7. Realistic-size JSON context evaluates safely. Note Jexl
  //    element-0 drill semantics: filter + .score yields the FIRST
  //    active record's score.
  let records : Array[@ast.Value] = []
  for i in 0..<1000 {
    records.push(
      v_obj([
        ("id", v_num(i.to_double())),
        ("active", @ast.BoolVal(i % 2 == 0)),
        ("score", v_num((i % 100).to_double())),
      ]),
    )
  }
  let r7 = @jexl.Jexl::eval(
    inst,
    "records[.active].score",
    v_obj([("records", @ast.ArrayVal(records))]),
  ) catch {
    @jexl.JexlErr(msg) => abort("json ctx failed: " + msg)
  }
  assert_true(@ast.value_equal(r7, v_num(0.0)))
}

///|
test "stability suite on Walk engine" {
  stability_suite(false)
}

///|
test "stability suite on Vm engine" {
  stability_suite(true)
}

///|
test "walk and vm agree across the stability workload" {
  // Cross-engine agreement: run representative expressions on both
  // engines and compare results against each other.
  let items : Array[@ast.Value] = []
  for i in 0..<20 {
    items.push(
      @ast.ObjectVal([
        ("name", @ast.StrVal("n" + i.to_string())),
        ("qty", @ast.NumVal((i % 5).to_double())),
      ]),
    )
  }
  let ctx = @ast.ObjectVal([("items", @ast.ArrayVal(items))])
  let exprs = [
    "items[.qty > 2].name ?? 'none'", "items[0].name", "len(items)", "items[.active2 ?? false]",
  ]
  for expr in exprs {
    let rw = try {
      let i = @jexl.new_jexl()
      Ok(@jexl.Jexl::eval(i, expr, ctx))
    } catch {
      @jexl.JexlErr(m) => Err(m)
    }
    let rv = try {
      let i = @jexl.new_jexl()
      @jexl.Jexl::set_engine(i, Vm)
      Ok(@jexl.Jexl::eval(i, expr, ctx))
    } catch {
      @jexl.JexlErr(m) => Err(m)
    }
    match (rw, rv) {
      (Ok(a), Ok(b)) => assert_true(parity_value_eq(a, b))
      (Err(m1), Err(m2)) => assert_eq(m1, m2)
      (_, _) => abort("walk/vm disagreement on " + expr)
    }
  }
}
