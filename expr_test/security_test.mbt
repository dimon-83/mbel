// SPDX-License-Identifier: Apache-2.0
// Security hardening tests: resource-exhaustion guards introduced by
// the security assessment — user-function recursion cap, range Int64
// span, source-length caps, repeat output cap, deep-nesting guards.
// Every engine-reachable case is asserted on BOTH engines; guards must
// produce clean errors instead of host-stack traps on all three
// targets (native/wasm-gc/js).

///|
/// Evaluates an expr source against a fresh engine (selected mode),
/// returning the stringified value or "ERR:<message>".
fn sec_eval(code : String, ctx : @ast.Value, vm : Bool) -> String raise {
  let e = @engine.new()
  if vm {
    @engine.Engine::set_engine(e, @engine.Vm)
  }
  @evaluator.to_string(@engine.Engine::eval_expr(e, code, ctx)) catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
/// Same expectation on Walk and Vm.
fn sec_both(code : String, ctx : @ast.Value, expected : String) -> Unit raise {
  assert_eq(sec_eval(code, ctx, false), expected)
  assert_eq(sec_eval(code, ctx, true), expected)
}

///|
/// Evaluates on the classic (legacy) entry.
fn sec_legacy(code : String, ctx : @ast.Value) -> String raise {
  let e = @engine.new()
  @evaluator.to_string(@engine.Engine::eval(e, code, ctx)) catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
fn long_source(n : Int) -> String {
  let b = StringBuilder::new()
  for _ in 0..<n {
    b.write_char('x')
  }
  b.to_string()
}

///|
/// A value nested `depth` container levels deep: objects {"a": {...}}
/// or arrays [[[...]]].
fn deep_value(depth : Int, arrays : Bool) -> @ast.Value {
  let mut v : @ast.Value = if arrays {
    @ast.ArrayVal([])
  } else {
    @ast.ObjectVal([])
  }
  for _ in 0..<depth {
    v = if arrays { @ast.ArrayVal([v]) } else { @ast.ObjectVal([("a", v)]) }
  }
  v
}

///|
test "security: user-function recursion raises, then the engine recovers" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "loop", params: None, body: "loop()" },
    { name: "fact", params: Some(["n"]), body: "n <= 1 ? 1 : n * fact(n - 1)" },
  ]
  for vm in [false, true] {
    let got = uf_eval_str(defs, None, "loop()", @ast.ObjectVal([]), vm)
    assert_true(
      got.contains("function call depth exceeded (more than 256 levels)"),
    )
    assert_true(got.contains("\"loop\":"))
    // deep-but-legal recursion still works (fact(10) needs 10 frames)
    assert_eq(
      uf_eval_str(defs, None, "fact(10)", @ast.ObjectVal([]), vm),
      "int:3628800",
    )
  }
  // the depth counter restores on error: same engine keeps working
  let e = @engine.new()
  ignore(@engine.Engine::add_expression_functions(e, defs, None))
  let r1 = try? @engine.Engine::eval_expr(e, "loop()", @ast.ObjectVal([]))
  match r1 {
    Err(_) => ()
    Ok(_) => fail("loop() must raise the depth guard")
  }
  let r2 = try? @engine.Engine::eval_expr(e, "fact(5)", @ast.ObjectVal([]))
  match r2 {
    Ok(@ast.IntVal(120L)) => ()
    other => fail("engine must recover after the guard: " + uf_dbg(other))
  }
}

///|
test "security: mutual recursion across definitions is capped" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "ping", params: None, body: "pong()" },
    { name: "pong", params: None, body: "ping()" },
  ]
  for vm in [false, true] {
    let got = uf_eval_str(defs, None, "ping()", @ast.ObjectVal([]), vm)
    assert_true(
      got.contains("function call depth exceeded (more than 256 levels)"),
    )
  }
}

///|
test "security: range span overflow (Int64) and boundary" {
  sec_both(
    "(-2147483648)..2147483647",
    @ast.ObjectVal([]),
    "ERR:memory budget exceeded",
  )
  sec_both("(0)..1000001", @ast.ObjectVal([]), "ERR:memory budget exceeded")
  // the 1e6-element boundary still passes
  sec_both("len((0)..1000000)", @ast.ObjectVal([]), "1000001")
}

///|
test "security: source-length cap before tokenization (both dialects)" {
  let big = long_source(200000)
  // standard dialect: a single huge string literal is one token, so
  // the node budget alone could never reject it
  let got = sec_eval("\"" + big + "\"", @ast.ObjectVal([]), false)
  assert_true(
    got.contains("expression is too large (more than 160000 characters)"),
  )
  // classic dialect entry has the same cap
  let legacy = sec_legacy("\"" + big + "\"", @ast.ObjectVal([]))
  assert_true(
    legacy.contains("expression is too large (more than 160000 characters)"),
  )
  // a normal-sized literal still parses and evaluates
  let small = long_source(5000)
  let ok = sec_eval("\"" + small + "\"", @ast.ObjectVal([]), false)
  assert_eq(ok.length(), 5000)
}

///|
test "security: repeat caps the OUTPUT size, not just the count" {
  // count within 1e6 but output above it (len 3 x 400000)
  sec_both(
    "repeat(\"abc\", 400000)",
    @ast.ObjectVal([]),
    "ERR:repeat: invalid count",
  )
  // count above 1e6 stays rejected
  sec_both(
    "repeat(\"x\", 1000001)",
    @ast.ObjectVal([]),
    "ERR:repeat: invalid count",
  )
  // output exactly at the cap still works
  let ok = sec_eval("repeat(\"x\", 1000000)", @ast.ObjectVal([]), false)
  assert_eq(ok.length(), 1000000)
}

///|
test "security: deep-nested values raise instead of overflowing (==, toJSON)" {
  let deep_obj = deep_value(1500, false)
  let ctx : @ast.Value = @ast.ObjectVal([("x", deep_obj)])
  sec_both("x == x", ctx, "ERR:value nesting too deep (more than 1024 levels)")
  sec_both(
    "toJSON(x)", ctx, "ERR:value nesting too deep (more than 1024 levels)",
  )
}

///|
test "security: deep array serialization and flatten are bounded" {
  let deep_arr = deep_value(1500, true)
  // stringification truncates past the cap instead of recursing
  let s = @evaluator.to_string(deep_arr)
  assert_true(s.contains("…"))
  let ctx : @ast.Value = @ast.ObjectVal([("x", deep_arr)])
  sec_both(
    "flatten(x)", ctx, "ERR:cannot flatten nested array: max depth reached",
  )
}
