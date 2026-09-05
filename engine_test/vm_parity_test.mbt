// SPDX-License-Identifier: Apache-2.0
// mbel — Walk vs Vm internal parity tests (dual-engine safety net).
//
// Both engines share one semantic layer (evaluator/semantics.mbt and
// the shared dispatch functions), so they can only diverge in
// dispatch. These tests make any such divergence loud: the whole
// differential corpus plus hand-written cases covering every node
// type, operator, builtin, and budget behavior runs on both engines
// and the results — including error messages — must match exactly.

///|
/// Result type for cross-engine comparison (value or error message).
fn parity_eval(
  mode : @engine.EngineMode,
  expr : String,
  ctx : @ast.Value,
) -> Result[@ast.Value, String] {
  let inst = @engine.new()
  @engine.Engine::set_engine(inst, mode)
  Ok(@engine.Engine::eval(inst, expr, ctx)) catch {
    @engine.EngineErr(msg) => Err(msg)
  }
}

///|
fn ctx_from_json(json : String) -> @ast.Value {
  if json == "" {
    return @ast.ObjectVal([])
  }
  let j = @json.parse(json) catch { _ => abort("bad corpus json: " + json) }
  @builtin.json_to_value(j)
}

///|
/// NaN-aware value equality for parity purposes: two engines both
/// producing NaN is agreement, not divergence.
fn parity_value_eq(a : @ast.Value, b : @ast.Value) -> Bool {
  match (a, b) {
    (@ast.NumVal(x), @ast.NumVal(y)) => x == y || (x != x && y != y)
    (_, _) => @ast.value_equal(a, b)
  }
}

///|
fn expect_parity(expr : String, ctx_json : String, label : String) -> Unit {
  let ctx = ctx_from_json(ctx_json)
  let rw = parity_eval(Walk, expr, ctx)
  let rv = parity_eval(Vm, expr, ctx)
  match (rw, rv) {
    (Ok(a), Ok(b)) =>
      if !parity_value_eq(a, b) {
        abort(label + " parity mismatch on '" + expr + "': walk/vm differ")
      }
    (Err(m1), Err(m2)) =>
      if m1 != m2 {
        abort(
          label +
          " parity mismatch on '" +
          expr +
          "': errors differ ('" +
          m1 +
          "' vs '" +
          m2 +
          "')",
        )
      }
    (Ok(_), Err(m)) =>
      abort(
        label + " parity mismatch on '" + expr + "': walk ok, vm error: " + m,
      )
    (Err(m), Ok(_)) =>
      abort(
        label +
        " parity mismatch on '" +
        expr +
        "': walk error: " +
        m +
        ", vm ok",
      )
  }
}

// --- Hand-written cases: every node type and dispatch path ---

///|
test "vm parity: arithmetic and precedence" {
  expect_parity("1+2*3", "", "arith1")
  expect_parity("(2+3)*4", "", "arith2")
  expect_parity("2+3*4==5/6-7", "", "arith3")
  expect_parity("7//2", "", "floordiv")
  expect_parity("-7%4", "", "mod")
  expect_parity("2^10", "", "pow")
  expect_parity("0.1+0.2", "", "float")
  expect_parity("1/0", "", "inf")
  expect_parity("0/0", "", "nan")
}

///|
test "vm parity: comparisons and logic (short-circuit)" {
  expect_parity("2 > 1", "", "cmp1")
  expect_parity("\"5\" < \"10\"", "", "cmp lex")
  expect_parity("0 && 5", "", "and short")
  expect_parity("2 && 3", "", "and value")
  expect_parity("0 || \"x\"", "", "or short")
  expect_parity("\"foo\" && 6 >= 6 && 0 + 1 && true", "", "and chain")
  expect_parity("!true", "", "not")
  expect_parity("!!0", "", "not2")
  expect_parity("1 == \"1\"", "", "loose eq")
  expect_parity("[] == \"\"", "", "array eq")
}

///|
test "vm parity: ternary and coalescing" {
  expect_parity("\"a\" ? \"b\" : \"c\"", "", "ternary")
  expect_parity("0 ? 1 : 2", "", "ternary false")
  expect_parity("\"foo\" ?: \"bar\"", "", "elvis")
  expect_parity("missing ?? \"fallback\"", "", "coalesce")
  expect_parity("1 ?? 2", "", "coalesce left")
  expect_parity("a.b ?? \"x\"", "", "coalesce drill")
}

///|
test "vm parity: identifiers, chains, filters" {
  expect_parity("foo.bar", "{\"foo\":{\"bar\":42}}", "chain")
  expect_parity("foo.bar.baz", "{\"foo\":{\"bar\":{\"baz\":7}}}", "chain2")
  expect_parity(
    "assoc[.first == \"Lana\"].last", "{\"assoc\":[{\"first\":\"Lana\",\"last\":\"Kane\"},{\"first\":\"Cyril\",\"last\":\"Figgis\"}]}",
    "filter drill",
  )
  expect_parity(
    "items[.qty > 2]", "{\"items\":[{\"qty\":1},{\"qty\":3},{\"qty\":5}]}", "filter array",
  )
  expect_parity("a[.b]", "{}", "filter empty")
  expect_parity("foo", "{\"foo\":null}", "null ctx")
  expect_parity("[1,2,3][1]", "", "array index")
  expect_parity("{a: 1, b: 2}.b", "", "object literal")
  expect_parity("{\"k\" + \"1\": \"v\"}.k1", "", "computed key")
}

///|
test "vm parity: arrays, objects, in, range, matches" {
  expect_parity("\"bar\" in \"foobartek\"", "", "in str")
  expect_parity("2 in [1,2,3]", "", "in arr")
  expect_parity("1..3 == [1,2,3]", "", "range")
  expect_parity("len(1..10)", "", "range len")
  expect_parity("\"hello\" matches \"ell\"", "", "matches")
  expect_parity("\"hello\" matches \"xyz\"", "", "matches miss")
}

///|
test "vm parity: builtins and transforms" {
  expect_parity("abs(-5) + ceil(1.2) + floor(1.8)", "", "math")
  expect_parity("median([1, 9, 5])", "", "median")
  expect_parity("upper(\"abc\")", "", "upper")
  expect_parity("join([\"a\",\"b\"], \"-\")", "", "join")
  expect_parity("toJSON({a: 1})", "", "tojson")
  expect_parity("fromJSON(\"[1,2]\")[0]", "", "fromjson")
  expect_parity("bitand(12, 10)", "", "bitand")
  expect_parity("duration(\"1h\") == 3600000000000", "", "duration")
  expect_parity("5|dbl|dbl", "", "transform chain")
  expect_parity("[1,2,3]|first", "", "transform first")
}

///|
test "vm parity: custom operators incl. manual eval" {
  // eager custom op
  expect_parity("\"FoO\" _= \"fOo\"", "", "custom op")
  // manual-eval (lazy) custom op compiles to the callback path
  let walk = @engine.new()
  @engine.Engine::add_binary_op_manual(walk, "$$", 50, fn(
    l : @evaluator.Lazy,
    r : @evaluator.Lazy,
  ) -> @ast.Value raise @evaluator.EvalError {
    let lv = l()
    if @evaluator.to_number(lv) > 0.0 {
      lv
    } else {
      r()
    }
  })
  let vm = @engine.new()
  @engine.Engine::set_engine(vm, Vm)
  @engine.Engine::add_binary_op_manual(vm, "$$", 50, fn(
    l : @evaluator.Lazy,
    r : @evaluator.Lazy,
  ) -> @ast.Value raise @evaluator.EvalError {
    let lv = l()
    if @evaluator.to_number(lv) > 0.0 {
      lv
    } else {
      r()
    }
  })
  let rw = Ok(
    @engine.Engine::eval(
      walk,
      "2|inc $$ -5|inc",
      @ast.ObjectVal([("inc_unused", @ast.NumVal(0.0))]),
    ),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  // note: 'inc' transform is not registered on these instances; both
  // engines must fail identically
  let rv = Ok(
    @engine.Engine::eval(
      vm,
      "2|inc $$ -5|inc",
      @ast.ObjectVal([("inc_unused", @ast.NumVal(0.0))]),
    ),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  match (rw, rv) {
    (Err(m1), Err(m2)) => assert_eq(m1, m2)
    (_, _) =>
      abort("manual op: expected identical transform-not-defined errors")
  }
}

///|
test "vm parity: budgets behave equivalently" {
  let walk = @engine.new()
  let vm = @engine.new()
  @engine.Engine::set_engine(vm, Vm)
  for inst in [walk, vm] {
    @engine.Engine::set_limits(inst, 0, 0, 20)
  }
  let expr = "[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]+[0]"
  let rw = Ok(
    @engine.Engine::eval(walk, expr, @ast.ObjectVal([("a", @ast.NumVal(1.0))])),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  let rv = Ok(
    @engine.Engine::eval(vm, expr, @ast.ObjectVal([("a", @ast.NumVal(1.0))])),
  ) catch {
    @engine.EngineErr(m) => Err(m)
  }
  match (rw, rv) {
    (Err(m1), Err(m2)) => {
      assert_true(m1.contains("budget"))
      assert_eq(m1, m2)
    }
    (_, _) => abort("budget: both engines must exceed the 20-step budget")
  }
}

// --- Full differential corpus: Walk vs Vm ---

///|
test "vm parity: full differential corpus (207 exprs)" {
  assert_eq(corpus_exprs.length(), corpus_ctx_jsons.length())
  for i in 0..<corpus_exprs.length() {
    expect_parity(
      corpus_exprs[i],
      corpus_ctx_jsons[i],
      "corpus[" + i.to_string() + "]",
    )
  }
}
