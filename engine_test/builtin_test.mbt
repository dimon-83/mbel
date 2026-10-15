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
  expect_v("indexOf(\"hello\", \"ll\")", @ast.IntVal(2L), "indexOf")
  expect_v("indexOf(\"hello\", \"z\")", @ast.IntVal(-1L), "indexOf miss")
  expect_v("lastIndexOf(\"aXbX\", \"X\")", @ast.IntVal(3L), "lastIndexOf")
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
  expect_v("len(\"hello\")", @ast.IntVal(5L), "len str")
  expect_v("len([1,2,3])", @ast.IntVal(3L), "len arr")
  expect_v("len({a:1,b:2})", @ast.IntVal(2L), "len map")
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
  expect_v("int(3.9)", @ast.IntVal(3L), "int trunc")
  expect_v("int(-3.9)", @ast.IntVal(-3L), "int trunc neg")
  expect_v("int(\"42\")", @ast.IntVal(42L), "int str")
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
  // bit ops return exact ints (expr parity; 4.4.3 typed returns)
  expect_v("bitand(12, 10)", @ast.IntVal(8L), "bitand")
  expect_v("bitor(12, 10)", @ast.IntVal(14L), "bitor")
  expect_v("bitxor(12, 10)", @ast.IntVal(6L), "bitxor")
  expect_v("bitnot(0)", @ast.IntVal(-1L), "bitnot")
  expect_v("bitshl(1, 4)", @ast.IntVal(16L), "bitshl")
  expect_v("bitshr(-16, 2)", @ast.IntVal(-4L), "bitshr arith")
  expect_v("bitushr(-16, 60)", @ast.IntVal(15L), "bitushr logical")
  expect_v("bitnand(35, 9)", @ast.IntVal(34L), "bitnand and-not (expr)")
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
  // 2023-08-14T00:00:00Z = 1691971200000 ms = 1691971200000000000 ns
  expect_v(
    "date(\"2023-08-14\") == 1691971200000000000",
    @ast.BoolVal(true),
    "date ymd",
  )
  expect_v(
    "date(\"2023-08-14T10:30:00Z\") == 1691971200000000000 + 37800000000000",
    @ast.BoolVal(true),
    "date time",
  )
  expect_err("date(\"not-a-date\")", "date", "bad date")
}

///|
test "now is a plausible unix-ns timestamp" {
  let r = eval1("now()") catch { @engine.EngineErr(msg) => abort(msg) }
  match r {
    // ns, not a double: the value exceeds 2^53.
    @ast.IntVal(ns) =>
      assert_true(ns > 1700000000000000000L && ns < 4000000000000000000L)
    _ => abort("now: expected an int64 nanosecond timestamp")
  }
}

///|
test "time values share one unit, so time arithmetic is meaningful" {
  // Time and duration are both int64 nanoseconds: this used to add
  // milliseconds to nanoseconds and return a meaningless number.
  expect_v(
    "date(\"2024-01-01\") + duration(\"24h\") == date(\"2024-01-02\")",
    @ast.BoolVal(true),
    "date + duration",
  )
  expect_v(
    "date(\"2024-01-02\") - date(\"2024-01-01\") == duration(\"24h\")",
    @ast.BoolVal(true),
    "date - date",
  )
  expect_v(
    "date(\"2024-01-02\") - date(\"2024-01-01\") == 86400000000000",
    @ast.BoolVal(true),
    "date difference is ns",
  )
  expect_v(
    "date(\"2024-06-15\") + duration(\"12h\") == date(\"2024-06-15T12:00:00Z\")",
    @ast.BoolVal(true),
    "date + half day",
  )
  // Subtracting a duration moves time backwards and stays comparable.
  expect_v(
    "date(\"2024-01-02\") - duration(\"24h\") == date(\"2024-01-01\")",
    @ast.BoolVal(true),
    "date - duration",
  )
  expect_v(
    "date(\"2024-01-01\") < date(\"2024-01-02\")",
    @ast.BoolVal(true),
    "date compare",
  )
  // now() is on the same scale.
  expect_v("now() - now() == 0", @ast.BoolVal(true), "now difference")
  expect_v(
    "now() - duration(\"1h\") < now()",
    @ast.BoolVal(true),
    "now - duration",
  )
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
  expect_v("len(1..10)", @ast.IntVal(10L), "range len")
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
test "matches operator (regex semantics)" {
  // `matches` compiles the right operand as a real regex (MoonBit core
  // regex). Divergences from Go RE2 are documented in
  // docs/coverage-vs-expr.md: no `\d`/`\w`/`\s` class escapes (use POSIX
  // classes) and `.` matches newline.
  expect_v("\"hello\" matches \"ell\"", @ast.BoolVal(true), "matches substr")
  expect_v("\"hello\" matches \"xyz\"", @ast.BoolVal(false), "matches miss")
  expect_v("\"hello\" matches \"hello\"", @ast.BoolVal(true), "matches full")
  // Anchors and the `.` wildcard are regex, not literal text.
  expect_v("\"hello\" matches \"^h.*o$\"", @ast.BoolVal(true), "matches anchors")
  expect_v("\"hello\" matches \"h.llo\"", @ast.BoolVal(true), "matches wildcard")
  expect_v("\"hello\" matches \"^e\"", @ast.BoolVal(false), "matches anchor miss")
  expect_v("\"hello\" matches \"o$\"", @ast.BoolVal(true), "matches end anchor")
  // Character classes and quantifiers.
  expect_v("\"abc123\" matches \"[0-9]+\"", @ast.BoolVal(true), "matches class")
  expect_v(
    "\"abc123\" matches \"[[:digit:]]+\"",
    @ast.BoolVal(true),
    "matches POSIX class",
  )
  expect_v("\"abc\" matches \"^[0-9]+$\"", @ast.BoolVal(false), "matches class miss")
  // Alternation and groups.
  expect_v("\"b\" matches \"a|b\"", @ast.BoolVal(true), "matches alternation hit")
  expect_v("\"x\" matches \"a|b\"", @ast.BoolVal(false), "matches alternation miss")
  expect_v("\"ab\" matches \"^(a|b)+$\"", @ast.BoolVal(true), "matches grouped alt")
  expect_v("\"HELLO\" matches \"(?i:hello)\"", @ast.BoolVal(true), "matches (?i:...)")
  // A malformed pattern is a runtime error, never a silent false.
  expect_err("\"hello\" matches \"[\"", "invalid regex", "matches invalid pattern")
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

///|
test "legacy dialect keeps JS type names and UTF-16 length" {
  // The deliberate other half of the dialect split documented in
  // typed_builtin_test.mbt: the same source means different things.
  expect_v("type(5.0)", @ast.StrVal("number"), "legacy float name")
  expect_v("len(\"\u{1F44D}\")", @ast.IntVal(2L), "legacy UTF-16 length")
  expect_v("len(\"\u{4EAC}\u{5317}\")", @ast.IntVal(2L), "BMP unchanged")
  // Astral literals used to be cut mid-surrogate: the lexer stripped the
  // quotes using the code-point count but sliced UTF-16 units, so
  // `"a👍b"` decoded to `a` plus a lone surrogate and lost the `b`.
  expect_v("\"a\u{1F44D}b\"", @ast.StrVal("a\u{1F44D}b"), "astral round-trip")
  expect_v("len(\"a\u{1F44D}b\")", @ast.IntVal(4L), "astral JS length")
}
