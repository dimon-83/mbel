// SPDX-License-Identifier: Apache-2.0
// Expression-defined user functions (engine/userfuncs.mbt): call and
// pipe syntax in all three dialects, auto-extracted parameters,
// env-default fallback, strict-mode whitelist, error paths — asserted
// on BOTH engines wherever the result is engine-visible.

///|
/// Evaluates `code` against a fresh engine with `defs` registered,
/// returning a typed discriminator string ("int:42", "float:3.5",
/// "undef", ...) or "ERR:<message>".
fn uf_eval_str(
  defs : Array[@engine.UserFunctionDef],
  defaults : @ast.Value?,
  code : String,
  env : @ast.Value,
  vm : Bool,
) -> String raise {
  let e = @engine.new()
  if vm {
    @engine.Engine::set_engine(e, @engine.Vm)
  }
  try {
    ignore(@engine.Engine::add_expression_functions(e, defs, defaults))
    let v = @engine.Engine::eval_expr(e, code, env)
    match v {
      @ast.IntVal(x) => "int:" + x.to_string()
      @ast.NumVal(d) =>
        if d != d {
          "float:nan"
        } else if d == 1.0 / 0.0 {
          "float:inf"
        } else if d == -1.0 / 0.0 {
          "float:-inf"
        } else {
          "float:" + d.to_string()
        }
      @ast.BoolVal(b) => "bool:" + (if b { "true" } else { "false" })
      @ast.StrVal(s) => "str:" + s
      @ast.UndefVal => "undef"
      @ast.NullVal => "null"
      other => "other:" + @evaluator.to_string(other)
    }
  } catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
/// Walk + Vm must agree (parity) — asserts the same expectation for
/// both engine selections.
fn uf_both(
  defs : Array[@engine.UserFunctionDef],
  defaults : @ast.Value?,
  code : String,
  env : @ast.Value,
  expected : String,
) -> Unit raise {
  assert_eq(uf_eval_str(defs, defaults, code, env, false), expected)
  assert_eq(uf_eval_str(defs, defaults, code, env, true), expected)
}

///|
/// Returns the registration error message, or "OK" when registration
/// succeeded.
fn uf_register_err(
  defs : Array[@engine.UserFunctionDef],
  defaults : @ast.Value?,
) -> String raise {
  let e = @engine.new()
  try {
    ignore(@engine.Engine::add_expression_functions(e, defs, defaults))
    "OK"
  } catch {
    @engine.EngineErr(m) => m
  }
}

///|
/// Resolved auto-extracted parameter list as "[a,b]".
fn uf_params(name : String, body : String) -> String raise {
  @engine.user_function_params(name, body).join(",")
}

///|
/// Classic-dialect (legacy Jexl) evaluation with defs registered.
fn uf_legacy(
  defs : Array[@engine.UserFunctionDef],
  code : String,
) -> String raise {
  let e = @engine.new()
  try {
    ignore(@engine.Engine::add_expression_functions(e, defs, None))
    match @engine.Engine::eval(e, code, @ast.ObjectVal([])) {
      @ast.NumVal(d) => "float:" + d.to_string()
      other => "other:" + @evaluator.to_string(other)
    }
  } catch {
    @engine.EngineErr(m) => "ERR:" + m
  }
}

///|
fn uf_double() -> Array[@engine.UserFunctionDef] {
  [{ name: "double", params: Some(["x"]), body: "x * 2" }]
}

///|
test "user function: direct call, standard pipe, cached Vm reuse" {
  uf_both(uf_double(), None, "double(21)", @ast.ObjectVal([]), "int:42")
  uf_both(uf_double(), None, "21 | double()", @ast.ObjectVal([]), "int:42")
  // two calls in one evaluation exercise the Vm program cache
  uf_both(
    uf_double(),
    None,
    "double(1) + double(2)",
    @ast.ObjectVal([]),
    "int:6",
  )
}

///|
test "user function: classic-dialect pipes and calls" {
  assert_eq(uf_legacy(uf_double(), "21|double"), "float:42")
  assert_eq(uf_legacy(uf_double(), "double(21)"), "float:42")
}

///|
test "auto-extracted params: free identifiers, first-appearance order" {
  assert_eq(uf_params("tax", "price * rate"), "price,rate")
  assert_eq(uf_params("swap", "b + a"), "b,a")
  // let-bound names are not free
  assert_eq(uf_params("t", "let t = price * 2; t + rate"), "price,rate")
  // callees are not free
  assert_eq(uf_params("n", "len(items)"), "items")
  // relative predicate identifiers are not free
  assert_eq(uf_params("s", "sum(xs, .price > minPrice)"), "xs,minPrice")
  // member drill-down roots are not free
  assert_eq(uf_params("g", "user.age >= minAge"), "minAge")
  // $env is never a parameter; folded-away bodies have none
  assert_eq(uf_params("e", "$env.price + 1"), "")
  assert_eq(uf_params("c", "1 + 2"), "")
  // duplicates collapse
  assert_eq(uf_params("d", "a + a * a"), "a")
}

///|
test "auto params bind positionally" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "tax", params: None, body: "price + rate" },
  ]
  uf_both(defs, None, "tax(100, 0.5)", @ast.ObjectVal([]), "float:100.5")
}

///|
test "env defaults: unpassed params fall back, explicit args win" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "tax", params: None, body: "price + rate" },
  ]
  let env : @ast.Value = @ast.ObjectVal([
    ("price", @ast.NumVal(100.0)),
    ("rate", @ast.NumVal(0.5)),
  ])
  uf_both(defs, Some(env), "tax()", env, "float:100.5")
  uf_both(defs, Some(env), "tax(200)", env, "float:200.5")
  uf_both(defs, Some(env), "tax(200, 1.5)", env, "float:201.5")
  // explicit args override same-named defaults
  let env2 : @ast.Value = @ast.ObjectVal([
    ("price", @ast.NumVal(1.0)),
    ("rate", @ast.NumVal(0.5)),
  ])
  uf_both(defs, Some(env2), "tax(9)", env2, "float:9.5")
  // purely lexical parameters (defaults None): an unpassed parameter is
  // undefined, so typed arithmetic on it raises
  let lexical = uf_eval_str(defs, None, "tax(100)", @ast.ObjectVal([]), false)
  assert_true(lexical.contains("invalid operation"))
}

///|
test "strict mode: registered functions pass the whitelist" {
  let e = @engine.new()
  ignore(@engine.Engine::add_expression_functions(e, uf_double(), None))
  let got = try? @engine.Engine::eval_expr_checked(
    e,
    "double(2) + double(3)",
    @ast.ObjectVal([]),
  )
  match got {
    Ok(@ast.IntVal(10L)) => ()
    other => fail("checked double: unexpected " + uf_dbg(other))
  }
  // unknown names still fail: the env whitelist catches bare
  // identifiers, unregistered CALLS surface at the runtime pool lookup
  let bad = try? @engine.Engine::eval_expr_checked(
    e,
    "nosuch(1)",
    @ast.ObjectVal([]),
  )
  match bad {
    Err(@engine.EngineErr(m)) =>
      assert_eq(m, "Jexl Function nosuch is not defined.")
    other => fail("unknown call: unexpected " + uf_dbg(other))
  }
}

///|
/// Debug rendering for Result values in failure messages.
fn uf_dbg(r : Result[@ast.Value, @engine.EngineError]) -> String {
  match r {
    Ok(v) => "ok:" + @evaluator.to_string(v)
    Err(@engine.EngineErr(m)) => "err:" + m
  }
}

///|
test "validation errors" {
  // names
  assert_eq(
    uf_register_err([{ name: "if", params: None, body: "1" }], None),
    "function name \"if\" is a keyword",
  )
  assert_eq(
    uf_register_err([{ name: "9bad", params: None, body: "1" }], None),
    "invalid function name \"9bad\"",
  )
  assert_eq(
    uf_register_err([{ name: "$env", params: None, body: "1" }], None),
    "function name \"$env\" is reserved",
  )
  assert_eq(
    uf_register_err([{ name: "map", params: None, body: "1" }], None),
    "function name \"map\" conflicts with an aggregate",
  )
  assert_eq(
    uf_register_err(
      [
        { name: "f", params: None, body: "1" },
        { name: "f", params: None, body: "2" },
      ],
      None,
    ),
    "duplicate function name \"f\"",
  )
  // parameters
  assert_eq(
    uf_register_err([{ name: "f", params: Some(["a-b"]), body: "1" }], None),
    "function \"f\": invalid parameter name \"a-b\"",
  )
  assert_eq(
    uf_register_err([{ name: "f", params: Some(["in"]), body: "1" }], None),
    "function \"f\": parameter name \"in\" is a keyword",
  )
  assert_eq(
    uf_register_err([{ name: "f", params: Some(["x", "x"]), body: "1" }], None),
    "function \"f\": duplicate parameter name \"x\"",
  )
  // bodies
  assert_eq(
    uf_register_err([{ name: "e", params: None, body: "" }], None),
    "function \"e\": parse error at 1:1: unexpected end of expression",
  )
  let bad_body = uf_register_err(
    [{ name: "bad", params: Some(["x"]), body: "x +" }],
    None,
  )
  assert_true(bad_body.contains("function \"bad\": parse error at 1:"))
  // defaults shape
  assert_eq(
    uf_register_err(uf_double(), Some(@ast.NumVal(1.0))),
    "function env defaults must be an object",
  )
}

///|
test "validation is atomic: a failing def leaves nothing registered" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "good", params: Some(["x"]), body: "x + 1" },
    { name: "bad", params: Some(["x"]), body: "x +" },
  ]
  assert_eq(uf_register_err(defs, None).contains("parse error"), true)
  let e = @engine.new()
  let res = try? @engine.Engine::add_expression_functions(e, defs, None)
  match res {
    Err(_) => ()
    Ok(_) => fail("registration should have failed")
  }
  let after = try? @engine.Engine::eval_expr(e, "good(1)", @ast.ObjectVal([]))
  match after {
    Err(@engine.EngineErr(m)) =>
      assert_eq(m, "Jexl Function good is not defined.")
    other => fail("good should be unregistered: " + uf_dbg(other))
  }
}

///|
test "ordinary builtins may be overridden (upsert)" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "abs", params: Some(["x"]), body: "x * 2" },
  ]
  uf_both(defs, None, "abs(-4)", @ast.ObjectVal([]), "int:-8")
}

///|
test "recursion and mutual references, registered out of order" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "fact", params: Some(["n"]), body: "n <= 1 ? 1 : n * fact(n - 1)" },
  ]
  uf_both(defs, None, "fact(5)", @ast.ObjectVal([]), "int:120")
  let mutual : Array[@engine.UserFunctionDef] = [
    { name: "a2", params: Some(["x"]), body: "b2(x) + 1" },
    { name: "b2", params: Some(["x"]), body: "x * 10" },
  ]
  uf_both(mutual, None, "a2(2)", @ast.ObjectVal([]), "int:21")
}

///|
test "engine mode may switch after registration" {
  let e = @engine.new()
  ignore(@engine.Engine::add_expression_functions(e, uf_double(), None))
  @engine.Engine::set_engine(e, @engine.Vm)
  let vm = try? @engine.Engine::eval_expr(e, "double(4)", @ast.ObjectVal([]))
  match vm {
    Ok(@ast.IntVal(8L)) => ()
    other => fail("vm after switch: " + uf_dbg(other))
  }
  @engine.Engine::set_engine(e, @engine.Walk)
  let walk = try? @engine.Engine::eval_expr(e, "double(4)", @ast.ObjectVal([]))
  match walk {
    Ok(@ast.IntVal(8L)) => ()
    other => fail("walk after switch: " + uf_dbg(other))
  }
}

///|
test "nullary auto params: body without free identifiers" {
  let defs : Array[@engine.UserFunctionDef] = [
    { name: "f", params: None, body: "1 + 2" },
  ]
  uf_both(defs, None, "f()", @ast.ObjectVal([]), "int:3")
}

///|
test "explicit params: clamp through builtins, both engines" {
  let defs : Array[@engine.UserFunctionDef] = [
    {
      name: "clamp",
      params: Some(["v", "lo", "hi"]),
      body: "max(min(v, hi), lo)",
    },
  ]
  uf_both(defs, None, "clamp(5, 1, 3)", @ast.ObjectVal([]), "int:3")
  uf_both(defs, None, "clamp(0, 1, 3)", @ast.ObjectVal([]), "int:1")
  uf_both(defs, None, "clamp(5, 1, 9)", @ast.ObjectVal([]), "int:5")
}
