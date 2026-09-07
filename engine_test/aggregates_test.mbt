// SPDX-License-Identifier: Apache-2.0
// mbel — expr predicate-aggregate tests (stage 4.4.2).
// Semantics follow expr-lang's language definition and builtin.go.

///|
let agg_users : @ast.Value = @ast.ObjectVal([
  (
    "users",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Bob")), ("age", @ast.NumVal(15.0))]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
      @ast.ObjectVal([("name", @ast.StrVal("Dan")), ("age", @ast.NumVal(40.0))]),
    ]),
  ),
  (
    "nums",
    @ast.ArrayVal([
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
      @ast.NumVal(5.0),
    ]),
  ),
])

///|
fn agg_eval(expr : String) -> @ast.Value raise @engine.EngineError {
  let inst = @engine.new()
  @engine.Engine::eval(inst, expr, agg_users)
}

///|
fn agg_eval_vm(expr : String) -> @ast.Value raise @engine.EngineError {
  let inst = @engine.new()
  @engine.Engine::set_engine(inst, Vm)
  @engine.Engine::eval(inst, expr, agg_users)
}

///|
fn expect_agg(expr : String, expected : @ast.Value, label : String) -> Unit {
  let r = agg_eval(expr) catch {
    @engine.EngineErr(msg) => abort(label + " walk failed: " + msg)
  }
  if !@ast.value_equal(r, expected) {
    abort(
      label + ": expected " + debug_repr(expected) + " got " + debug_repr(r),
    )
  }
  // Cross-engine parity: the VM must produce the same value.
  let rv = agg_eval_vm(expr) catch {
    @engine.EngineErr(msg) => abort(label + " vm failed: " + msg)
  }
  if !@ast.value_equal(r, rv) {
    abort(label + ": walk/vm diverged")
  }
}

///|
fn debug_repr(v : @ast.Value) -> String {
  match v {
    @ast.NumVal(d) => d.to_string()
    @ast.IntVal(i) => i.to_string()
    @ast.StrVal(s) => "\"" + s + "\""
    @ast.BytesVal(b) => {
      let parts : Array[String] = []
      for i in 0..<b.length() {
        parts.push(b[i].to_int().to_string())
      }
      "b[" + parts.join(",") + "]"
    }
    @ast.BoolVal(b) => if b { "true" } else { "false" }
    @ast.NullVal => "null"
    @ast.UndefVal => "undef"
    @ast.ArrayVal(xs) => {
      let parts = xs.map(debug_repr)
      "[" + parts.join(",") + "]"
    }
    @ast.ObjectVal(pairs) => {
      let parts = pairs.map(fn(kv) {
        let (k, v) = kv
        k + ":" + debug_repr(v)
      })
      "{" + parts.join(",") + "}"
    }
  }
}

// --- filter / map ---

///|
test "predicate: filter with relative field access" {
  expect_agg(
    "filter(users, .age >= 18)",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
      @ast.ObjectVal([("name", @ast.StrVal("Dan")), ("age", @ast.NumVal(40.0))]),
    ]),
    "filter rel",
  )
}

///|
test "predicate: filter with explicit pointer" {
  expect_agg(
    "filter(nums, # % 2 == 1)",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(3.0), @ast.NumVal(5.0)]),
    "filter #",
  )
}

///|
test "predicate: map with pointer and index" {
  expect_agg(
    "map(nums, # * 2)",
    @ast.ArrayVal([
      @ast.NumVal(2.0),
      @ast.NumVal(4.0),
      @ast.NumVal(6.0),
      @ast.NumVal(8.0),
      @ast.NumVal(10.0),
    ]),
    "map double",
  )
  expect_agg(
    "map(nums, #index)",
    @ast.ArrayVal([
      @ast.NumVal(0.0),
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
    ]),
    "map index",
  )
}

// --- all / any / none / one ---

///|
test "predicate: all/any/none/one" {
  expect_agg("all(users, .age > 10)", @ast.BoolVal(true), "all true")
  expect_agg("all(users, .age > 20)", @ast.BoolVal(false), "all false")
  expect_agg("any(users, .age > 35)", @ast.BoolVal(true), "any true")
  expect_agg("any(users, .age > 50)", @ast.BoolVal(false), "any false")
  expect_agg("none(users, .age > 50)", @ast.BoolVal(true), "none true")
  expect_agg("none(users, .age > 35)", @ast.BoolVal(false), "none false")
  expect_agg("one(nums, # == 3)", @ast.BoolVal(true), "one true")
  expect_agg("one(nums, # > 3)", @ast.BoolVal(false), "one two matches")
}

// --- count / sum ---

///|
test "predicate: count and sum" {
  expect_agg(
    "count([true, true, false, true, false])",
    @ast.IntVal(3L),
    "count no pred (bools)",
  )
  expect_agg("count(nums, # > 2)", @ast.IntVal(3L), "count pred")
  expect_agg("count(users, .age >= 18)", @ast.IntVal(3L), "count users")
  expect_agg("sum(nums)", @ast.NumVal(15.0), "sum no pred")
  expect_agg("sum(nums, # * 2)", @ast.NumVal(30.0), "sum pred")
}

// --- find family ---

///|
test "predicate: find/findIndex/findLast/findLastIndex" {
  expect_agg("find(nums, # > 2)", @ast.NumVal(3.0), "find")
  expect_agg("find(nums, # > 9)", @ast.NullVal, "find miss")
  expect_agg("findIndex(nums, # > 2)", @ast.IntVal(2L), "findIndex")
  expect_agg("findLast(nums, # > 2)", @ast.NumVal(5.0), "findLast")
  expect_agg("findLastIndex(nums, # > 2)", @ast.IntVal(4L), "findLastIndex")
}

// --- groupBy / sortBy ---

///|
test "predicate: groupBy and sortBy" {
  expect_agg(
    "groupBy(nums, # % 2)",
    @ast.ObjectVal([
      (
        "1",
        @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(3.0), @ast.NumVal(5.0)]),
      ),
      ("0", @ast.ArrayVal([@ast.NumVal(2.0), @ast.NumVal(4.0)])),
    ]),
    "groupBy parity",
  )
  expect_agg("sortBy(users, .age)[0].name", @ast.StrVal("Bob"), "sortBy asc")
  expect_agg(
    "sortBy(users, .age, \"desc\")[0].name",
    @ast.StrVal("Dan"),
    "sortBy desc",
  )
}

// --- reduce ---

///|
test "predicate: reduce with #acc" {
  expect_agg("reduce(nums, #acc + #)", @ast.NumVal(15.0), "reduce no init")
  expect_agg("reduce(nums, #acc + #, 100)", @ast.NumVal(115.0), "reduce init")
  expect_agg(
    "reduce(nums, #acc + #index, 0)",
    @ast.NumVal(10.0),
    "reduce index",
  )
}

// --- nesting and ranges ---

///|
test "predicate: nested aggregates and ranges" {
  expect_agg("sum(1..100)", @ast.NumVal(5050.0), "sum range")
  expect_agg(
    "filter(1..10, # % 3 == 0)",
    @ast.ArrayVal([@ast.NumVal(3.0), @ast.NumVal(6.0), @ast.NumVal(9.0)]),
    "filter range",
  )
  expect_agg(
    "count(filter([true, false, true, false], #))",
    @ast.IntVal(2L),
    "count of filter",
  )
  expect_agg("sum(map(nums, # * #))", @ast.NumVal(55.0), "sum of squares")
  expect_agg(
    "all(users, any([], # > 0))",
    @ast.BoolVal(false),
    "nested empty any",
  )
}

// --- errors ---

///|
test "predicate: aggregates require a list" {
  try {
    ignore(agg_eval("filter(5, # > 2)"))
    abort("expected error for non-list")
  } catch {
    @engine.EngineErr(_) => ()
  }
}
