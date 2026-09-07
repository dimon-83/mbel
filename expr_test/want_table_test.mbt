// SPDX-License-Identifier: Apache-2.0
// GENERATED from expr-lang v1.17.8's official TestExpr want table
// (test/expr_test.go, 167 rows) — the stage-4.4 gate acceptance
// artifact (docs/coverage-vs-expr.md §6.3 item ⑤).
//
// Environment: mock.Env's data fields mirrored as engine Values; the
// env's Go functions (Add/GetInt/Variadic) are registered per the
// reflection cut (host functions = registered functions). Wants are
// normalized to canonical JSON and compared through the same canon
// serializer the corpus driver uses, on BOTH engines per row.
//
// Skipped rows (19/167), each with its documented reason:
//   row 026: in on struct/map membership (legacy JS in-semantics lock)
//   row 033: matches with regex metachars (mbel regex is literal-only — documented cut)
//   row 034: matches with dynamic pattern (regex cut)
//   row 042: Go method call (reflection cut)
//   row 043: Go method call (reflection cut)
//   row 049: len counts UTF-16 units vs expr rune count (documented divergence)
//   row 050: len counts UTF-16 units vs expr rune count (documented divergence)
//   row 066: time arithmetic (stage 4.5)
//   row 094: time arithmetic (stage 4.5)
//   row 095: time arithmetic (stage 4.5)
//   row 096: time arithmetic (stage 4.5)
//   row 097: time arithmetic (stage 4.5)
//   row 098: time arithmetic (stage 4.5)
//   row 099: time arithmetic (stage 4.5)
//   row 100: time arithmetic (stage 4.5)
//   row 101: time arithmetic (stage 4.5)
//   row 103: time arithmetic (stage 4.5)
//   row 151: want table carries doubles (json parse rounds >2^53); exact uint64 asserted in eval_test
//   row 155: nil-safe ?. chains yield undefined vs expr nil (documented divergence)

///|
fn want_row_env() -> Array[(String, @ast.Value)] {
  [
    ("Int", IntVal(0L)),
    ("Int32", IntVal(0L)),
    ("Int64", IntVal(0L)),
    ("Uint32", IntVal(0L)),
    ("Uint64", IntVal(0L)),
    ("Float64", NumVal(0.0)),
    ("Bool", BoolVal(true)),
    ("String", StrVal("string")),
    ("One", IntVal(1L)),
    ("Two", IntVal(2L)),
    (
      "Foo",
      ObjectVal([
        ("Value", StrVal("foo")),
        ("Bar", ObjectVal([("Baz", StrVal("baz"))])),
      ]),
    ),
    (
      "ArrayOfInt",
      ArrayVal([IntVal(1L), IntVal(2L), IntVal(3L), IntVal(4L), IntVal(5L)]),
    ),
    (
      "ArrayOfFoo",
      ArrayVal([
        ObjectVal([("Value", StrVal("foo"))]),
        ObjectVal([("Value", StrVal("bar"))]),
        ObjectVal([("Value", StrVal("baz"))]),
      ]),
    ),
    ("Any", NullVal),
    ("NilAny", NullVal),
    ("NilFn", NullVal),
    ("NilStruct", NullVal),
    ("NilInt", NullVal),
    ("NilSlice", NullVal),
    ("NilStr", NullVal),
  ]
}

///|
fn want_new_engine(mode : @engine.EngineMode) -> @engine.Engine {
  let e = @engine.new()
  @engine.Engine::set_engine(e, mode)
  @engine.Engine::add_function(e, "Add", fn(args) {
    @ast.NumVal(@evaluator.to_number(args[0]) + @evaluator.to_number(args[1]))
  })
  @engine.Engine::add_function(e, "GetInt", fn(args) {
    ignore(args)
    @ast.NumVal(0.0)
  })
  @engine.Engine::add_function(e, "Variadic", fn(args) {
    let head = @evaluator.to_number(args[0])
    let mut sum = 0.0
    for i in 1..<args.length() {
      sum = sum + @evaluator.to_number(args[i])
    }
    @ast.BoolVal(head == sum)
  })
  e
}

///|
/// Canon serializer mirroring cmd/main's (the corpus-diff format):
/// objects keep insertion order with quoted keys, arrays compact,
/// strings JSON-escaped, bytes as bytes[97,98].
fn want_canon(v : @ast.Value) -> String {
  let buf = StringBuilder::new()
  fn go(v : @ast.Value) -> Unit {
    match v {
      @ast.BoolVal(b) => buf.write_string(if b { "true" } else { "false" })
      @ast.NumVal(d) =>
        if d != d {
          buf.write_string("\"NaN\"")
        } else if d == 1.0 / 0.0 {
          buf.write_string("\"Inf\"")
        } else if d == -1.0 / 0.0 {
          buf.write_string("\"-Inf\"")
        } else {
          buf.write_string(d.to_string())
        }
      @ast.IntVal(i) => buf.write_string(i.to_string())
      @ast.StrVal(s) => {
        buf.write_string("\"")
        for c in s {
          match c {
            '"' => buf.write_string("\\\"")
            '\\' => buf.write_string("\\\\")
            '\n' => buf.write_string("\\n")
            _ => buf.write_char(c)
          }
        }
        buf.write_string("\"")
      }
      @ast.BytesVal(b) => {
        buf.write_string("bytes[")
        for i in 0..<b.length() {
          if i > 0 {
            buf.write_string(",")
          }
          buf.write_string(b[i].to_int().to_string())
        }
        buf.write_string("]")
      }
      @ast.NullVal => buf.write_string("null")
      @ast.UndefVal => buf.write_string("undefined")
      @ast.ArrayVal(xs) => {
        buf.write_string("[")
        for i in 0..<xs.length() {
          if i > 0 {
            buf.write_string(",")
          }
          go(xs[i])
        }
        buf.write_string("]")
      }
      @ast.ObjectVal(pairs) => {
        buf.write_string("{")
        for i in 0..<pairs.length() {
          let (k, val) = pairs[i]
          if i > 0 {
            buf.write_string(",")
          }
          buf.write_string("\"" + k + "\":")
          go(val)
        }
        buf.write_string("}")
      }
    }
  }

  go(v)
  buf.to_string()
}

///|
let want_rows : Array[(String, String, String)] = [
  ("r000", "1", "1"),
  ("r001", "-.5", "-0.5"),
  ("r002", "true && false || false", "false"),
  (
    "r003", "Int == 0 && Int32 == 0 && Int64 == 0 && Float64 == 0 && Bool && String == \"string\"",
    "true",
  ),
  ("r004", "-Int64 == 0", "true"),
  ("r005", "\"a\" != \"b\"", "true"),
  ("r006", "\"a\" != \"b\" || 1 == 2", "true"),
  ("r007", "Int + 0", "0"),
  ("r008", "Uint64 + 0", "0"),
  ("r009", "Uint64 + Int64", "0"),
  ("r010", "Int32 + Int64", "0"),
  ("r011", "Float64 + 0", "0"),
  ("r012", "0 + Float64", "0"),
  ("r013", "0 <= Float64", "true"),
  ("r014", "Float64 < 1", "true"),
  ("r015", "Int < 1", "true"),
  ("r016", "2 + 2 == 4", "true"),
  ("r017", "8 % 3", "2"),
  ("r018", "2 ** 8", "256"),
  ("r019", "2 ^ 8", "256"),
  ("r020", "-(2-5)**3-2/(+4-3)+-2", "23"),
  ("r021", "\"hello\" + \" \" + \"world\"", "\"hello world\""),
  ("r022", "0 in -1..1 and 1 in 1..1", "true"),
  ("r023", "Int in 0..1", "true"),
  ("r024", "Int32 in 0..1", "true"),
  ("r025", "Int64 in 0..1", "true"),
  ("r027", "1 in [1.5] || 1 not in [1]", "false"),
  ("r028", "One in 0..1 && Two not in 0..1", "true"),
  ("r029", "Two not in 0..1", "true"),
  ("r030", "Two not    in 0..1", "true"),
  ("r031", "-1 not in [1]", "true"),
  ("r032", "Int32 in [10, 20]", "false"),
  ("r035", "'foo' + 'bar' not matches 'foobar'", "false"),
  ("r036", "\"foobar\" contains \"bar\"", "true"),
  ("r037", "\"foobar\" startsWith \"foo\"", "true"),
  ("r038", "\"foobar\" endsWith \"bar\"", "true"),
  ("r039", "(0..10)[5]", "5"),
  ("r040", "Foo.Bar.Baz", "\"baz\""),
  ("r041", "Add(10, 5) + GetInt()", "15"),
  ("r044", "len([1, 2, 3])", "3"),
  ("r045", "len([1, Two, 3])", "3"),
  ("r046", "len([\"hello\", \"world\"])", "2"),
  ("r047", "len(\"hello, world\")", "12"),
  ("r048", "len('北京')", "2"),
  ("r051", "len(ArrayOfInt)", "5"),
  ("r052", "len({a: 1, b: 2, c: 2})", "3"),
  ("r053", "max([1, 2, 3])", "3"),
  ("r054", "max(1, 2, 3)", "3"),
  ("r055", "min([1, 2, 3])", "1"),
  ("r056", "min(1, 2, 3)", "1"),
  ("r057", "{foo: 0, bar: 1}", "{\"foo\":0,\"bar\":1}"),
  ("r058", "{foo: 0, bar: 1}", "{\"foo\":0,\"bar\":1}"),
  ("r059", "(true ? 0+1 : 2+3) + (false ? -1 : -2)", "-1"),
  ("r060", "filter(1..9, {# > 7})", "[8,9]"),
  ("r061", "map(1..3, {# * #})", "[1,4,9]"),
  ("r062", "all(1..3, {# > 0})", "true"),
  ("r063", "count(1..30, {# % 3 == 0})", "10"),
  ("r064", "count([true, true, false])", "2"),
  ("r065", "\"a\" < \"b\"", "true"),
  ("r067", "1 + 1", "2"),
  ("r068", "(One * Two) * 3 == One * (Two * 3)", "true"),
  ("r069", "ArrayOfInt[1]", "2"),
  ("r070", "ArrayOfInt[0] < ArrayOfInt[1]", "true"),
  ("r071", "ArrayOfInt[-1]", "5"),
  ("r072", "ArrayOfInt[1:2]", "[2]"),
  ("r073", "ArrayOfInt[1:4]", "[2,3,4]"),
  ("r074", "ArrayOfInt[-4:-1]", "[2,3,4]"),
  ("r075", "ArrayOfInt[:3]", "[1,2,3]"),
  ("r076", "ArrayOfInt[3:]", "[4,5]"),
  ("r077", "ArrayOfInt[0:5] == ArrayOfInt", "true"),
  ("r078", "ArrayOfInt[0:] == ArrayOfInt", "true"),
  ("r079", "ArrayOfInt[:5] == ArrayOfInt", "true"),
  ("r080", "ArrayOfInt[:] == ArrayOfInt", "true"),
  ("r081", "4 in 5..1", "false"),
  ("r082", "4..0", "[]"),
  ("r083", "NilStruct", "null"),
  (
    "r084", "NilAny == nil && nil == NilAny && nil == nil && NilAny == NilAny && NilInt == nil && NilSlice == nil && NilStruct == nil",
    "true",
  ),
  ("r085", "0 == nil || \"str\" == nil || true == nil", "false"),
  ("r086", "Variadic(6, 1, 2, 3)", "true"),
  ("r087", "Variadic(0)", "true"),
  ("r088", "String[:]", "\"string\""),
  ("r089", "String[:3]", "\"str\""),
  ("r090", "String[:9]", "\"string\""),
  ("r091", "String[3:9]", "\"ing\""),
  ("r092", "String[7:9]", "\"\""),
  ("r093", "map(filter(ArrayOfInt, # >= 3), # + 1)", "[4,5,6]"),
  ("r102", "duration(\"1h\") == duration(\"1h\")", "true"),
  ("r104", "duration(\"1h\") > duration(\"1m\")", "true"),
  ("r105", "duration(\"1h\") < duration(\"1m\")", "false"),
  ("r106", "duration(\"1h\") >= duration(\"1m\")", "true"),
  ("r107", "duration(\"1h\") <= duration(\"1m\")", "false"),
  ("r108", "duration(\"1h\") > duration(\"1m\")", "true"),
  ("r109", "duration(\"1h\") + duration(\"1m\")", "3660000000000"),
  ("r110", "duration(\"1h\") - duration(\"1m\")", "3540000000000"),
  ("r111", "7 * duration(\"1h\")", "25200000000000"),
  ("r112", "duration(\"1h\") * 7", "25200000000000"),
  ("r113", "duration(\"1s\") * .5", "5e8"),
  ("r114", "1 /* one */ + 2 // two", "3"),
  ("r115", "let x = 1; x + 2", "3"),
  ("r116", "map(1..3, let x = #; let y = x * x; y * y)", "[1,16,81]"),
  ("r117", "map(1..2, let x = #; map(2..3, let y = #; x + y))", "[[3,4],[4,5]]"),
  ("r118", "len(filter(1..99, # % 7 == 0))", "14"),
  ("r119", "find(ArrayOfFoo, .Value == \"baz\")", "{\"Value\":\"baz\"}"),
  ("r120", "findIndex(ArrayOfFoo, .Value == \"baz\")", "2"),
  ("r121", "filter(ArrayOfFoo, .Value == \"baz\")[0]", "{\"Value\":\"baz\"}"),
  (
    "r122", "first(filter(ArrayOfFoo, .Value == \"baz\"))", "{\"Value\":\"baz\"}",
  ),
  ("r123", "first(filter(ArrayOfFoo, false))", "null"),
  ("r124", "findLast(1..9, # % 2 == 0)", "8"),
  ("r125", "findLastIndex(1..9, # % 2 == 0)", "7"),
  ("r126", "{\"r\": findLast([1, 2, 3, 4, 5], # > 3)}", "{\"r\":5}"),
  ("r127", "{\"r\": findLastIndex([1, 2, 3, 4, 5], # > 3)}", "{\"r\":4}"),
  ("r128", "{\"r\": findLast([1, 2, 3], # > 10)}", "{\"r\":null}"),
  (
    "r129", "{\"a\": findLast([1, 2, 3], # > 1), \"b\": findLastIndex([4, 5, 6], # > 4)}",
    "{\"a\":3,\"b\":2}",
  ),
  ("r130", "filter(1..9, # % 2 == 0)[-1]", "8"),
  ("r131", "last(filter(1..9, # % 2 == 0))", "8"),
  ("r132", "map(filter(1..9, # % 2 == 0), # * 2)", "[4,8,12,16]"),
  ("r133", "map(map(filter(1..9, # % 2 == 0), # * 2), # * 2)", "[8,16,24,32]"),
  ("r134", "first(map(filter(1..9, # % 2 == 0), # * 2))", "4"),
  ("r135", "map(filter(1..9, # % 2 == 0), # * 2)[-1]", "16"),
  ("r136", "len(map(filter(1..9, # % 2 == 0), # * 2))", "4"),
  ("r137", "len(filter(map(1..9, # * 2), # % 2 == 0))", "9"),
  ("r138", "first(filter(map(1..9, # * 2), # % 2 == 0))", "2"),
  ("r139", "first(map(filter(1..9, # % 2 == 0), # * 2))", "4"),
  ("r140", "2^3 == 8", "true"),
  ("r141", "4/2 == 2", "true"),
  ("r142", ".5 in 0..1", "false"),
  ("r143", ".5 in ArrayOfInt", "false"),
  ("r144", "bitnot(10)", "-11"),
  ("r145", "bitxor(15, 32)", "47"),
  ("r146", "bitand(90, 34)", "2"),
  ("r147", "bitnand(35, 9)", "34"),
  ("r148", "bitor(10, 5)", "15"),
  ("r149", "bitshr(7, 2)", "1"),
  ("r150", "bitshl(7, 2)", "28"),
  ("r152", "\"hello\"[1:3]", "\"el\""),
  ("r153", "[1, 2, 3]?.[0]", "1"),
  ("r154", "[[1, 2], 3, 4]?.[0]?.[1]", "2"),
  ("r156", "1 > 2 < 3", "false"),
  ("r157", "1 < 2 < 3", "true"),
  ("r158", "1 < 2 < 3 > 4", "false"),
  ("r159", "1 < 2 < 3 > 2", "true"),
  ("r160", "1 < 2 < 3 == true", "true"),
  ("r161", "if 1 > 2 { 333 * 2 + 1 } else { 444 }", "444"),
  (
    "r162", "let a = 3;\n\t\t\tlet b = 2;\n\t\t\tif a>b {let c = Add(a, b); c+1} else {Add(10, b)}\n\t\t\t",
    "6",
  ),
  ("r163", "if \"a\" < \"b\" {let x = \"a\"; x} else {\"abc\"}", "\"a\""),
  (
    "r164", "if 1 == 2 { \"no\" } else if 1 == 1 { \"yes\" } else { \"maybe\" }",
    "\"yes\"",
  ),
  ("r165", "1; 2; 3", "3"),
  ("r166", "let a = 1; Add(2, 2); let b = 2; a + b", "3"),
]

///|
test "expr want table: expr-lang TestExpr rows on both engines" {
  let fails = StringBuilder::new()
  let mut ran = 0
  for row in want_rows {
    let (label, code, want_json) = row
    let parsed = @json.parse(want_json) catch { _ => @json.parse("null") }
    let want_c = want_canon(@builtin.json_to_value(parsed))
    for mode in [@engine.Walk, @engine.Vm] {
      let mode_name = match mode {
        @engine.Walk => "walk"
        @engine.Vm => "vm"
      }
      let made = try? want_new_engine(mode)
      match made {
        Ok(e) => {
          let res = try? @engine.Engine::eval_expr(
            e,
            code,
            @ast.ObjectVal(want_row_env()),
          )
          match res {
            Ok(v) => {
              ran += 1
              let got = want_canon(v)
              if got != want_c {
                fails.write_string(
                  label +
                  " (" +
                  mode_name +
                  ") " +
                  code +
                  " : got " +
                  got +
                  " want " +
                  want_c +
                  "\n",
                )
              }
            }
            Err(@engine.EngineErr(m)) =>
              fails.write_string(
                label + " (" + mode_name + ") ERR: " + m + "\n",
              )
            Err(_) =>
              fails.write_string(label + " (" + mode_name + ") ERR (unknown)\n")
          }
        }
        Err(_) => fails.write_string(label + " env: engine build failed\n")
      }
    }
  }
  if fails.to_string() != "" {
    inspect("ran=" + ran.to_string() + "\n" + fails.to_string(), content="")
  }
}
