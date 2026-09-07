// SPDX-License-Identifier: Apache-2.0
// expr front-end evaluation tests: expr syntax -> lower -> legacy AST
// -> both engines. Every case asserts Walk and Vm agree.

///|
let eval_ctx : @ast.Value = @ast.ObjectVal([
  ("x", @ast.NumVal(3.0)),
  ("age", @ast.NumVal(36.0)),
  ("name", @ast.StrVal("Archer")),
  (
    "users",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Bob")), ("age", @ast.NumVal(15.0))]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
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
fn expected_str(v : @ast.Value) -> String {
  @evaluator.to_string(v)
}

///|
fn eval_both(
  src : String,
) -> (@ast.Value, @ast.Value) raise @engine.EngineError {
  let w = @engine.new()
  let v = @engine.new()
  @engine.Engine::set_engine(v, Vm)
  // expr-dialect entry point: new front-end + dual-engine core
  let rw = @engine.Engine::eval_expr(w, src, eval_ctx)
  let rv = @engine.Engine::eval_expr(v, src, eval_ctx)
  (rw, rv)
}

///|
fn expect_eval(
  src : String,
  expected : @ast.Value,
  label : String,
) -> Unit raise {
  let (rw, rv) = eval_both(src) catch {
    @engine.EngineErr(msg) => abort(label + " failed: " + msg)
  }
  let nan_eq = match (rw, rv) {
    (@ast.NumVal(a), @ast.NumVal(b)) => a == b || (a != a && b != b)
    (_, _) => false
  }
  if !@ast.value_equal(rw, expected) {
    inspect(@evaluator.to_string(rw), content=expected_str(expected))
  }
  if !(@ast.value_equal(rw, rv) || nan_eq) {
    inspect(
      "walk=" + @evaluator.to_string(rw) + " vm=" + @evaluator.to_string(rv),
      content="identical",
    )
  }
}

///|
fn expect_eval_err(src : String, frag : String, label : String) -> Unit raise {
  try {
    ignore(eval_both(src))
    abort(label + ": expected error")
  } catch {
    @engine.EngineErr(msg) =>
      if !msg.contains(frag) {
        inspect(msg, content="error containing '" + frag + "'")
      }
  }
}

// --- expr-only literals evaluated through lowering ---

///|
test "expr eval: literal family" {
  expect_eval("0x2A + 0b1000", @ast.NumVal(50.0), "hex+bin")
  expect_eval("10_000 / 4", @ast.NumVal(2500.0), "underscore")
  expect_eval("2 ** 10", @ast.NumVal(1024.0), "power")
  expect_eval("14 / 2", @ast.NumVal(7.0), "division (// is a comment in expr)")
  expect_eval("1..5 == [1,2,3,4,5]", @ast.BoolVal(true), "range eq")
}

///|
test "expr eval: comparisons and chains" {
  expect_eval("1 < x && x < 10", @ast.BoolVal(true), "explicit chain")
  expect_eval("0 < 1 < 2", @ast.BoolVal(true), "true chain")
  expect_eval("2 < 1 < 5", @ast.BoolVal(false), "false chain")
  expect_eval("1 + 2 == 3", @ast.BoolVal(true), "arith eq")
}

///|
test "expr eval: nil coalescing and members" {
  expect_eval("name ?? \"none\"", @ast.StrVal("Archer"), "coalesce value")
  expect_eval("missing ?? \"none\"", @ast.StrVal("none"), "coalesce missing")
  expect_eval(
    "user?.name ?? \"nobody\"",
    @ast.StrVal("nobody"),
    "optional chain nil-safe",
  )
}

///|
test "expr eval: not-suffixed operators" {
  expect_eval("x not in [1, 2]", @ast.BoolVal(true), "not in")
  expect_eval("name not matches \"^L\"", @ast.BoolVal(true), "not matches")
}

///|
test "expr eval: predicates through braces and bare form" {
  expect_eval(
    "filter(users, {.age >= 18})",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "brace pred",
  )
  expect_eval(
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
  expect_eval(
    "filter(users, {#.age >= 18})",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "explicit pointer member",
  )
  expect_eval(
    "filter(users, .age >= 18)",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "relative field",
  )
  expect_eval("count(nums, # > 2)", @ast.IntVal(3L), "count")
  expect_eval("sum(nums, # * #)", @ast.NumVal(55.0), "sum squares")
  expect_eval("reduce(nums, #acc + #)", @ast.NumVal(15.0), "reduce")
  expect_eval("findIndex(nums, # == 4)", @ast.IntVal(3L), "findIndex")
}

///|
test "expr eval: unknown pointer suffix is a compile error" {
  // expr supports only `#`, `#index`, `#acc` — `#age` must not
  // silently read as the whole element.
  expect_eval_err(
    "filter(users, {#age >= 18})", "unknown pointer", "bad pointer",
  )
}

///|
test "expr eval: aggregates inside range and nested" {
  expect_eval("sum(1..100)", @ast.NumVal(5050.0), "sum range")
  expect_eval("count(filter(nums, # > 2))", @ast.IntVal(3L), "count filter")
}

// --- stage 4.4.1/4.4.2 evaluation: sequences, let, slices, $env ---

///|
test "expr eval: sequences and let" {
  expect_eval("1; 2; 3", @ast.NumVal(3.0), "seq value is last")
  expect_eval("let x = 2; x * 3", @ast.NumVal(6.0), "let basic")
  expect_eval("let a = 1; let b = a + 1; a + b", @ast.NumVal(3.0), "let chain")
  expect_eval(
    "let x = 1; let x = x + 1; x",
    @ast.NumVal(2.0),
    "redeclaration shadows (Eval-mode expr semantics)",
  )
  expect_eval("1; let x = 5; x", @ast.NumVal(5.0), "let mid-sequence")
  expect_eval(
    "(let x = 1; x + 1) * 3",
    @ast.NumVal(6.0),
    "let in parens is an expression",
  )
  expect_eval("x + 1", @ast.NumVal(4.0), "ctx untouched by local x")
  expect_eval(
    "let n = 2; count(nums, # > n)",
    @ast.NumVal(3.0),
    "predicate reads outer let",
  )
  expect_eval(
    "let k = 2; map(nums, # * k)",
    @ast.ArrayVal([
      @ast.NumVal(2.0),
      @ast.NumVal(4.0),
      @ast.NumVal(6.0),
      @ast.NumVal(8.0),
      @ast.NumVal(10.0),
    ]),
    "aggregate pred inherits locals on both engines",
  )
}

///|
test "expr eval: if/else is a value with sequence branches" {
  expect_eval(
    "if age > 20 { \"adult\" } else { \"minor\" }",
    @ast.StrVal("adult"),
    "if else",
  )
  expect_eval(
    "if age > 100 { \"old\" } else if age > 20 { \"adult\" } else { \"minor\" }",
    @ast.StrVal("adult"),
    "else if",
  )
  expect_eval(
    "if false { let y = 99; y } else { let x = 2; x * 10 }",
    @ast.NumVal(20.0),
    "let inside branch",
  )
  expect_eval(
    "let y = 5; (if false { let y = 1; y } else { 0 }) + y",
    @ast.NumVal(5.0),
    "branch let does not leak",
  )
  expect_eval(
    "(if age > 20 { 1; 2 } else { 3 }) * 10",
    @ast.NumVal(20.0),
    "sequence branch value",
  )
}

///|
test "expr eval: slices" {
  expect_eval(
    "nums[1:3]",
    @ast.ArrayVal([@ast.NumVal(2.0), @ast.NumVal(3.0)]),
    "slice",
  )
  expect_eval(
    "nums[:2]",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0)]),
    "open from",
  )
  expect_eval(
    "nums[2:]",
    @ast.ArrayVal([@ast.NumVal(3.0), @ast.NumVal(4.0), @ast.NumVal(5.0)]),
    "open to",
  )
  expect_eval(
    "nums[-2:]",
    @ast.ArrayVal([@ast.NumVal(4.0), @ast.NumVal(5.0)]),
    "negative from",
  )
  expect_eval("nums[5:]", @ast.ArrayVal([]), "past end clamps to empty")
  expect_eval(
    "nums[:] ",
    @ast.ArrayVal([
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
      @ast.NumVal(5.0),
    ]),
    "full slice",
  )
  expect_eval("\"hello\"[1:3]", @ast.StrVal("el"), "string slice")
  expect_eval("\"hello\"[-2:]", @ast.StrVal("lo"), "string negative")
  expect_eval(
    "let n = 4; nums[:n]",
    @ast.ArrayVal([
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
    ]),
    "bound from a let",
  )
  expect_eval_err("nums[1.5:3]", "slice bounds must be integers", "float bound")
  expect_eval_err("(age)[1:]", "cannot slice number", "slice number")
}

///|
test "expr eval: $env and member/index on it" {
  expect_eval("$env.age", @ast.NumVal(36.0), "$env member")
  expect_eval("$env[\"name\"]", @ast.StrVal("Archer"), "$env index")
  expect_eval(
    "'nums' in keys($env)",
    @ast.BoolVal(true),
    "key in $env via keys",
  )
  expect_eval("len($env)", @ast.IntVal(5L), "len of $env")
}

///|
test "expr eval: string operators (contains family)" {
  expect_eval("\"hello\" contains \"ell\"", @ast.BoolVal(true), "contains")
  expect_eval(
    "\"hello\" not contains \"xyz\"",
    @ast.BoolVal(true),
    "not contains",
  )
  expect_eval("\"hello\" startsWith \"he\"", @ast.BoolVal(true), "startsWith")
  expect_eval("\"hello\" endsWith \"lo\"", @ast.BoolVal(true), "endsWith")
  expect_eval("nil contains \"x\"", @ast.BoolVal(false), "nil-safe")
}

///|
test "expr eval: unary precedence and unary minus on expressions" {
  expect_eval("-2 ** 2", @ast.NumVal(-4.0), "-(2**2)")
  expect_eval("2 ** -2", @ast.NumVal(0.25), "negative exponent")
  expect_eval("-(1 + 2) * 3", @ast.NumVal(-9.0), "unary on expression")
  expect_eval("-x + 1", @ast.NumVal(-2.0), "unary on identifier")
  expect_eval("-2 * 3", @ast.NumVal(-6.0), "-2*3 = (-2)*3")
}

///|
test "expr eval: escape family through string values" {
  expect_eval("\"\\101\"", @ast.StrVal("A"), "octal escape")
  expect_eval("\"\\u{1F600}\"", @ast.StrVal("\u{1F600}"), "u{} escape")
  expect_eval("\"\\x41\"", @ast.StrVal("A"), "hex escape")
}

// --- byte test helpers: expr_test is blackbox, build Bytes via core ---

///|
fn bytes_lit(s : String) -> Bytes {
  // core's String::to_bytes is UTF-16; build ASCII bytes directly
  // (all byte literals in these tests are ASCII)
  let arr : Array[Byte] = s.to_array().map(fn(c) { c.to_int().to_byte() })
  Bytes::from_array(arr)
}

///|
fn bytes_lit_raw(xs : Array[Int]) -> Bytes {
  let arr : Array[Byte] = xs.map(fn(x) { x.to_byte() })
  Bytes::from_array(arr)
}

// --- byte strings evaluate as BytesVal (expr []byte semantics) ---

///|
test "expr eval: byte string literals and typed operations" {
  expect_eval("b\"abc\"", @ast.BytesVal(bytes_lit("abc")), "bytes literal")
  expect_eval("b\"\\xff\"", @ast.BytesVal(bytes_lit_raw([255])), "hex escape")
  expect_eval("len(b\"abc\")", @ast.IntVal(3L), "len of bytes is an int")
  expect_eval("len(b\"\\xff\\x00\")", @ast.IntVal(2L), "len counts raw bytes")
  // bytewise equality; bytes are a distinct kind from strings
  expect_eval("b\"a\" == b\"a\"", @ast.BoolVal(true), "bytes eq")
  expect_eval("b\"a\" != b\"b\"", @ast.BoolVal(true), "bytes neq")
  expect_eval("b\"a\" == \"a\"", @ast.BoolVal(false), "bytes vs string false")
  expect_eval("b\"a\" == nil", @ast.BoolVal(false), "bytes vs nil false")
  expect_eval("b\"\" == b\"\"", @ast.BoolVal(true), "empty bytes eq")
  expect_eval("b\"a\" == b\"b\"", @ast.BoolVal(false), "bytes neq 2")
}

///|
test "expr eval: byte strings reject arithmetic and ordering" {
  // expr runtime messages name byte slices []uint8 (Go type name)
  expect_eval_err(
    "b\"a\" + b\"b\"", "invalid operation: []uint8 + []uint8", "bytes + bytes",
  )
  expect_eval_err(
    "b\"a\" + 1", "invalid operation: []uint8 + int", "bytes + int",
  )
  expect_eval_err(
    "\"x\" + b\"y\"", "invalid operation: string + []uint8", "string + bytes",
  )
  expect_eval_err(
    "b\"a\" < b\"b\"", "invalid operation: []uint8 < []uint8", "bytes ordering",
  )
}

///|
test "expr eval: byte indexing, slicing and type()" {
  expect_eval("b\"abc\"[1]", @ast.IntVal(98L), "bytes index is an int")
  expect_eval("b\"abc\"[0] == 97", @ast.BoolVal(true), "byte value compare")
  expect_eval("b\"abc\"[0] + 1", @ast.IntVal(98L), "byte int arithmetic")
  // expr supports negative indices on []byte
  expect_eval("b\"abc\"[-1]", @ast.IntVal(99L), "negative bytes index")
  expect_eval("b\"abc\"[1:3]", @ast.BytesVal(bytes_lit("bc")), "bytes slice")
  expect_eval("b\"abc\"[1:3] == b\"bc\"", @ast.BoolVal(true), "sliced bytes eq")
  // expr type() reports "array" for []byte too
  expect_eval("type(b\"a\")", @ast.StrVal("array"), "type of bytes")
  // string() prints decimal content comma-joined (mbel's array
  // convention; expr prints Go's "[97 98 99]" — documented)
  expect_eval("string(b\"abc\")", @ast.StrVal("97,98,99"), "string of bytes")
  // toJSON encodes []byte as a base64 string (Go json.Marshal)
  expect_eval("toJSON(b\"a\")", @ast.StrVal("\"YQ==\""), "toJSON of bytes")
}

///|
test "expr eval: aggregates and filters over byte strings" {
  // bytes iterate as their int elements (expr: []byte is a uint8 slice)
  expect_eval(
    "filter(b\"abc\", # > 97)",
    @ast.ArrayVal([@ast.IntVal(98L), @ast.IntVal(99L)]),
    "filter over bytes",
  )
  expect_eval("count(b\"abc\", # > 97)", @ast.IntVal(2L), "count over bytes")
  expect_eval("sum(b\"abc\")", @ast.IntVal(294L), "sum of bytes")
  expect_eval(
    "map(b\"abc\", # + 1)",
    @ast.ArrayVal([@ast.IntVal(98L), @ast.IntVal(99L), @ast.IntVal(100L)]),
    "map over bytes",
  )
  expect_eval("first(b\"abc\")", @ast.IntVal(97L), "first of bytes")
  expect_eval("last(b\"abc\")", @ast.IntVal(99L), "last of bytes")
}

///|
test "expr eval: method calls surface clean errors" {
  expect_eval_err("name.upper()", "method call", "method on data")
}

///|
test "expr eval: parse errors surface with location" {
  expect_eval_err("1 +", "parse error at", "incomplete")
}

///|
test "expr eval: ?? mixing with other operators errors" {
  // expr: `??` (precedence 500) may not be followed by another binary
  // operator at the same level; `1 + 2 ?? 3` is fine (?? binds inside).
  expect_eval_err("1 ?? 2 + 3", "cannot be mixed", "?? then +")
  expect_eval_err("foo ?? bar || baz", "cannot be mixed", "?? then ||")
  expect_eval_err(
    "1 + 2 ?? 3 + 4", "cannot be mixed", "?? then + after operand",
  )
  expect_eval("(1 ?? 2) + 3", @ast.NumVal(4.0), "parenthesized ?? ok")
  expect_eval("1 + 2 ?? 3", @ast.NumVal(3.0), "?? binds tighter than +")
  expect_eval("a ?? b ?? 7", @ast.NumVal(7.0), "chained ?? ok")
}

// --- piped aggregates: the subject takes call-arg 0, so the first
// explicit argument is the predicate (expr's parseCall(ident,[left])).

///|
test "expr eval: piped aggregates parse predicate arguments" {
  expect_eval(
    "nums | map(# * 2)",
    @ast.ArrayVal([
      @ast.NumVal(2.0),
      @ast.NumVal(4.0),
      @ast.NumVal(6.0),
      @ast.NumVal(8.0),
      @ast.NumVal(10.0),
    ]),
    "pipe map pointer",
  )
  expect_eval(
    "users | filter(.age >= 18)",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "pipe filter bare dot",
  )
  expect_eval(
    "users | filter(.age >= 18) | map(.name) | first()",
    @ast.StrVal("Alice"),
    "piped chain with first()",
  )
  expect_eval(
    "users | filter({.age >= 18}) | count()",
    @ast.NumVal(2.0),
    "braced piped predicate + count()",
  )
}

// --- Jexl-compat bracket predicates: `items[.expr]` filters per
// element (expr-lang has no bracket form; documented extension).

///|
test "expr eval: bracket predicates filter relative to the element" {
  expect_eval(
    "users[.age >= 18]",
    @ast.ArrayVal([
      @ast.ObjectVal([
        ("name", @ast.StrVal("Alice")),
        ("age", @ast.NumVal(30.0)),
      ]),
      @ast.ObjectVal([("name", @ast.StrVal("Cyx")), ("age", @ast.NumVal(24.0))]),
    ]),
    "bracket predicate filters",
  )
  expect_eval(
    "users[.name == \"Bob\"].age",
    @ast.NumVal(15.0),
    "bracket predicate then member chain",
  )
  expect_eval(
    "users[.age >= 18] | map(.name)",
    @ast.ArrayVal([@ast.StrVal("Alice"), @ast.StrVal("Cyx")]),
    "bracket predicate feeds pipe",
  )
}

// --- expr alignment: pointers live only in predicate context; the
// pipe's right side must be a parenthesized call.

///|
test "expr eval: pointer and pipe strictness" {
  expect_eval_err("# + 1", "parse error at", "top-level pointer")
  expect_eval_err("nums[#]", "parse error at", "pointer in index position")
  expect_eval_err("nums | first", "unexpected token after '|'", "bare pipe")
  expect_eval_err("1 | 2", "unexpected token after '|'", "pipe to non-call")
}
