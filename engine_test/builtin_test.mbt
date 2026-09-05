// SPDX-License-Identifier: Apache-2.0
// mbel — builtin library + expr-operator tests (stage 4.2/4.3).
// Semantics follow expr-lang's builtin.go and language definition.

///|
fn eval1(expr : String) -> @ast.Value raise @engine.EngineError {
  let inst = @engine.new()
  @engine.Engine::eval(inst, expr, @ast.ObjectVal([]))
}

///|
fn expect_v(expr : String, expected : @ast.Value, label : String) -> Unit {
  let r = eval1(expr) catch {
    @engine.EngineErr(msg) => abort(label + " failed: " + msg)
  }
  if !@ast.value_equal(r, expected) {
    abort(label + ": value mismatch")
  }
}

///|
fn expect_err(expr : String, frag : String, label : String) -> Unit {
  try {
    ignore(eval1(expr))
    abort(label + ": expected error")
  } catch {
    @engine.EngineErr(msg) =>
      if !msg.contains(frag) {
        abort(label + ": error '" + msg + "' lacks '" + frag + "'")
      }
  }
}

// --- Math builtins ---

///|
test "math builtins follow expr semantics" {
  expect_v("abs(-5)", @ast.NumVal(5.0), "abs")
  expect_v("abs(5)", @ast.NumVal(5.0), "abs pos")
  expect_v("ceil(5.5)", @ast.NumVal(6.0), "ceil")
  expect_v("ceil(5)", @ast.NumVal(5.0), "ceil int")
  expect_v("floor(5.8)", @ast.NumVal(5.0), "floor")
  // Go math.Round: half away from zero (JS would give -2 for -2.5).
  expect_v("round(2.5)", @ast.NumVal(3.0), "round up")
  expect_v("round(-2.5)", @ast.NumVal(-3.0), "round half away")
  expect_v("max(3, 1, 2)", @ast.NumVal(3.0), "max")
  expect_v("min(3, 1, 2)", @ast.NumVal(1.0), "min")
  expect_v("max([1, 5, 3])", @ast.NumVal(5.0), "max array")
  expect_v("mean([2, 4, 6])", @ast.NumVal(4.0), "mean")
  expect_v("median([1, 9, 5])", @ast.NumVal(5.0), "median odd")
  expect_v("median([1, 2, 9, 10])", @ast.NumVal(5.5), "median even")
}

// --- String builtins ---

///|
test "string builtins follow expr semantics" {
  expect_v("trim(\"  hi  \")", @ast.StrVal("hi"), "trim")
  expect_v("trimPrefix(\"foobar\", \"foo\")", @ast.StrVal("bar"), "trimPrefix")
  expect_v("trimSuffix(\"foobar\", \"bar\")", @ast.StrVal("foo"), "trimSuffix")
  expect_v("upper(\"abc\")", @ast.StrVal("ABC"), "upper")
  expect_v("lower(\"ABC\")", @ast.StrVal("abc"), "lower")
  expect_v("split(\"a,b,c\", \",\")[1]", @ast.StrVal("b"), "split")
  expect_v("splitAfter(\"a,b\", \",\")[0]", @ast.StrVal("a,"), "splitAfter")
  expect_v("replace(\"aXbXc\", \"X\", \"-\")", @ast.StrVal("a-b-c"), "replace")
  expect_v("repeat(\"ab\", 3)", @ast.StrVal("ababab"), "repeat")
  expect_v("join([\"a\",\"b\",\"c\"], \"-\")", @ast.StrVal("a-b-c"), "join")
  expect_v("indexOf(\"hello\", \"ll\")", @ast.NumVal(2.0), "indexOf")
  expect_v("indexOf(\"hello\", \"z\")", @ast.NumVal(-1.0), "indexOf miss")
  expect_v("lastIndexOf(\"aXbX\", \"X\")", @ast.NumVal(3.0), "lastIndexOf")
  expect_v("hasPrefix(\"foobar\", \"foo\")", @ast.BoolVal(true), "hasPrefix")
  expect_v("hasSuffix(\"foobar\", \"baz\")", @ast.BoolVal(false), "hasSuffix")
  expect_v("string(42)", @ast.StrVal("42"), "string")
}

///|
test "repeat rejects oversized counts" {
  expect_err("repeat(\"a\", 1000001)", "repeat", "repeat cap")
}

// --- Collection builtins ---

///|
test "collection builtins follow expr semantics" {
  expect_v("len(\"hello\")", @ast.NumVal(5.0), "len str")
  expect_v("len([1,2,3])", @ast.NumVal(3.0), "len arr")
  expect_v("len({a:1,b:2})", @ast.NumVal(2.0), "len map")
  expect_v("first([7,8])", @ast.NumVal(7.0), "first")
  expect_v("first([])", @ast.NullVal, "first empty")
  expect_v("last([7,8])", @ast.NumVal(8.0), "last")
  expect_v("get([7,8,9], 5)", @ast.NullVal, "get OOB nil")
  expect_v("get([7,8,9], 1)", @ast.NumVal(8.0), "get index")
  expect_v("get({a:1}, \"b\")", @ast.NullVal, "get key miss")
  expect_v(
    "take([1,2,3,4], 2)",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0)]),
    "take",
  )
  expect_v(
    "keys({a:1,b:2})",
    @ast.ArrayVal([@ast.StrVal("a"), @ast.StrVal("b")]),
    "keys",
  )
  expect_v(
    "values({a:1,b:2})",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0)]),
    "values",
  )
  expect_v(
    "reverse([1,2,3])",
    @ast.ArrayVal([@ast.NumVal(3.0), @ast.NumVal(2.0), @ast.NumVal(1.0)]),
    "reverse",
  )
  expect_v(
    "uniq([1,1,2,2,3])",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0), @ast.NumVal(3.0)]),
    "uniq",
  )
  expect_v(
    "concat([1,2],[3],[4])",
    @ast.ArrayVal([
      @ast.NumVal(1.0),
      @ast.NumVal(2.0),
      @ast.NumVal(3.0),
      @ast.NumVal(4.0),
    ]),
    "concat",
  )
  expect_v(
    "flatten([1,[2,[3]]])",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0), @ast.NumVal(3.0)]),
    "flatten",
  )
  expect_v(
    "sort([3,1,2])",
    @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0), @ast.NumVal(3.0)]),
    "sort",
  )
  expect_v(
    "sort([\"b\",\"a\"])",
    @ast.ArrayVal([@ast.StrVal("a"), @ast.StrVal("b")]),
    "sort str",
  )
}

// --- Conversion builtins ---

///|
test "conversion builtins follow expr semantics" {
  expect_v("int(3.9)", @ast.NumVal(3.0), "int trunc")
  expect_v("int(-3.9)", @ast.NumVal(-3.0), "int trunc neg")
  expect_v("int(\"42\")", @ast.NumVal(42.0), "int str")
  expect_v("float(2)", @ast.NumVal(2.0), "float")
  expect_v("type(\"x\")", @ast.StrVal("string"), "type str")
  expect_v("type(1)", @ast.StrVal("number"), "type num")
  expect_v("type([1])", @ast.StrVal("array"), "type arr")
  expect_v(
    "toJSON({a: 1, b: [true]})",
    @ast.StrVal("{\"a\":1,\"b\":[true]}"),
    "toJSON",
  )
  expect_v("fromJSON(\"[1,2,3]\")[1]", @ast.NumVal(2.0), "fromJSON")
  expect_v("toPairs({a:1})[0][0]", @ast.StrVal("a"), "toPairs key")
  expect_v("fromPairs([[\"a\", 1]]).a", @ast.NumVal(1.0), "fromPairs")
}

///|
test "base64 round-trips UTF-8" {
  expect_v("toBase64(\"hello\")", @ast.StrVal("aGVsbG8="), "toBase64")
  expect_v("fromBase64(\"aGVsbG8=\")", @ast.StrVal("hello"), "fromBase64")
  expect_v(
    "fromBase64(toBase64(\"héllo ✓\"))",
    @ast.StrVal("héllo ✓"),
    "utf8 roundtrip",
  )
  expect_err("fromBase64(\"!!!\")", "base64", "bad base64")
}

///|
test "bitwise builtins follow Int64 semantics" {
  expect_v("bitand(12, 10)", @ast.NumVal(8.0), "bitand")
  expect_v("bitor(12, 10)", @ast.NumVal(14.0), "bitor")
  expect_v("bitxor(12, 10)", @ast.NumVal(6.0), "bitxor")
  expect_v("bitnot(0)", @ast.NumVal(-1.0), "bitnot")
  expect_v("bitshl(1, 4)", @ast.NumVal(16.0), "bitshl")
  expect_v("bitshr(-16, 2)", @ast.NumVal(-4.0), "bitshr arith")
  expect_v("bitushr(-16, 60)", @ast.NumVal(15.0), "bitushr logical")
}

// --- Time builtins (minimal subset) ---

///|
test "duration parses Go-style durations" {
  expect_v(
    "duration(\"1h30m\") == 5400000000000",
    @ast.BoolVal(true),
    "duration 1h30m",
  )
  expect_v(
    "duration(\"250ms\") == 250000000",
    @ast.BoolVal(true),
    "duration ms",
  )
  expect_v(
    "duration(\"1.5h\") == 5400000000000",
    @ast.BoolVal(true),
    "duration frac",
  )
  expect_err("duration(\"bogus\")", "duration", "bad duration")
}

///|
test "date parses ISO 8601" {
  // 2023-08-14T00:00:00Z = 1691971200000 ms
  expect_v(
    "date(\"2023-08-14\") == 1691971200000",
    @ast.BoolVal(true),
    "date ymd",
  )
  expect_v(
    "date(\"2023-08-14T10:30:00Z\") == 1691971200000 + 37800000",
    @ast.BoolVal(true),
    "date time",
  )
  expect_err("date(\"not-a-date\")", "date", "bad date")
}

///|
test "now is a plausible unix-ms timestamp" {
  let r = eval1("now()") catch { @engine.EngineErr(msg) => abort(msg) }
  match r {
    @ast.NumVal(d) => assert_true(d > 1700000000000.0 && d < 4000000000000.0)
    _ => abort("now: expected number")
  }
}

// --- expr operators: ?? .. matches ---

///|
test "nil coalescing operator" {
  expect_v("1 ?? 2", @ast.NumVal(1.0), "?? left")
  expect_v("missing ?? 2", @ast.NumVal(2.0), "?? right")
  expect_v("foo ?? bar ?? \"deep\"", @ast.StrVal("deep"), "?? chain")
  expect_v("a.b ?? \"x\"", @ast.StrVal("x"), "?? on drill")
  // Divergence (docs/expr-gap-analysis.md): expr rejects mixing ?? with
  // other binary operators at parse time; mbel accepts 1 + 2 ?? 3.
}

///|
test "range operator" {
  expect_v("1..3 == [1,2,3]", @ast.BoolVal(true), "range equals")
  expect_v("len(1..10)", @ast.NumVal(10.0), "range len")
  expect_v("5..5", @ast.ArrayVal([@ast.NumVal(5.0)]), "single range")
  expect_err("1.5..3", "integers", "range must be ints")
}

///|
test "range respects the step budget" {
  let inst = @engine.new()
  @engine.Engine::set_limits(inst, 0, 0, 100)
  try {
    ignore(@engine.Engine::eval(inst, "len(1..2000000)", @ast.ObjectVal([])))
    abort("expected budget error for huge range")
  } catch {
    @engine.EngineErr(msg) => assert_true(msg.contains("budget"))
  }
}

///|
test "matches operator (limited regex engine)" {
  // The MoonBit core regex engine currently behaves as literal
  // substring matching — full RE2-style patterns are a stage-4.5
  // follow-up (docs/expr-gap-analysis.md §E.2).
  expect_v("\"hello\" matches \"ell\"", @ast.BoolVal(true), "matches substr")
  expect_v("\"hello\" matches \"xyz\"", @ast.BoolVal(false), "matches miss")
  expect_v("\"hello\" matches \"hello\"", @ast.BoolVal(true), "matches full")
}

// --- Constant folding (stage 4.3) ---

///|
test "constant folding computes literal subtrees" {
  let inst = @engine.new()
  let toks = match @lexer.tokenize_with("1+2*3", inst.elements) {
    Ok(t) => t
    Err(m) => abort(m)
  }
  let ast = @parser.parse_with(toks, inst.elements) catch {
    @parser.ParseErr(m) => abort(m)
  }
  match ast {
    Some(node) => {
      let folded = @evaluator.constant_fold(node)
      assert_true(folded.node_type == @ast.LiteralNode)
      match folded.value {
        @ast.NumVal(d) => assert_eq(d, 7.0)
        _ => abort("fold: expected 7")
      }
    }
    None => abort("fold: empty ast")
  }
}

///|
test "folding preserves semantics" {
  expect_v("1+2*3", @ast.NumVal(7.0), "fold arith")
  expect_v("\"a\" + \"b\"", @ast.StrVal("ab"), "fold concat")
  expect_v("1 < 2 && 3 > 2", @ast.BoolVal(true), "fold cmp")
  // Non-foldable call around foldable range: folding composes with
  // evaluation.
  expect_v("len(1..3) * 2", @ast.NumVal(6.0), "fold + call")
}
