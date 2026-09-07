// SPDX-License-Identifier: Apache-2.0
// GENERATED from expr-lang v1.17.8 checker_test.go TestCheck — the
// "must compile cleanly" table (112 rows). mbel's strict entry must
// accept every program expr's checker accepts; the rows are compiled
// (check + lower), never executed. Env fields are bound as null
// (dynamic/unknown) values.
//
// Skipped rows (5/112), each with its documented reason:
//   row 019: trailing-dot float literal (2.) not lexed — lexer gap, recorded
//   row 059: Go method call (reflection cut)
//   row 069: Go method call (reflection cut)
//   row 078: Go method call (reflection cut)
//   row 111: Go method call (reflection cut)

///|
let check_ok_names : Array[(String, @ast.Value)] = [
  ("A", @ast.NullVal),
  ("Any", @ast.NullVal),
  ("Anything", @ast.NullVal),
  ("ArrayOfAny", @ast.NullVal),
  ("ArrayOfFoo", @ast.NullVal),
  ("ArrayOfInt", @ast.NullVal),
  ("ArrayOfString", @ast.NullVal),
  ("B", @ast.NullVal),
  ("Bar", @ast.NullVal),
  ("Baz", @ast.NullVal),
  ("Bool", @ast.NullVal),
  ("BoolPtr", @ast.NullVal),
  ("Contains", @ast.NullVal),
  ("Duration", @ast.NullVal),
  ("Embed", @ast.NullVal),
  ("EmbedMethod", @ast.NullVal),
  ("EmbedPointerEmbedInt", @ast.NullVal),
  ("EmbedString", @ast.NullVal),
  ("Fast", @ast.NullVal),
  ("Float", @ast.NullVal),
  ("Foo", @ast.NullVal),
  ("Func", @ast.NullVal),
  ("FuncFoo", @ast.NullVal),
  ("FuncParam", @ast.NullVal),
  ("FuncParamAny", @ast.NullVal),
  ("Int", @ast.NullVal),
  ("Int64", @ast.NullVal),
  ("IntPtr", @ast.NullVal),
  ("IntPtrPtr", @ast.NullVal),
  ("MapOfAny", @ast.NullVal),
  ("MapOfFoo", @ast.NullVal),
  ("String", @ast.NullVal),
  ("StringPtr", @ast.NullVal),
  ("Things", @ast.NullVal),
  ("Time", @ast.NullVal),
  ("Variadic", @ast.NullVal),
]

///|
let check_ok_rows : Array[String] = [
  "nil == nil", "nil == IntPtr", "nil == nil", "nil in ArrayOfFoo", "!Bool", "!BoolPtr == Bool",
  "'a' == 'b' + 'c'", "'foo' contains 'bar'", "'foo' endsWith 'bar'", "'foo' startsWith 'bar'",
  "(1 == 1) || (String matches Any)", "Int % Int > 1", "Int + Int + Int > 0", "Int == Any",
  "Int in Int..Int", "IntPtrPtr + 1 > 0", "1 + 2 + Int64 > 0", "Int64 % 1 > 0", "IntPtr == Int",
  "1 + 2 + Float + 3 + 4 < 0", "1 + Int + Float == 0.5", "-1 + +1 == 0", "1 / 2 == 0",
  "2**3 + 1 != 0", "2^3 + 1 != 0", "Float == 1", "Float < 1.0", "Float <= 1.0", "Float > 1.0",
  "Float >= 1.0", "\"a\" < \"b\"", "String + (true ? String : String) == ''", "(Any ? nil : '') == ''",
  "(Any ? 0 : nil) == 0", "(Any ? nil : nil) == nil", "!(Any ? Foo : Foo.Bar).Anything",
  "Int in ArrayOfInt", "Int not in ArrayOfAny", "String in ArrayOfAny", "String in ArrayOfString",
  "String in Foo", "String in MapOfFoo", "String matches 'ok'", "String matches Any",
  "String not matches Any", "StringPtr == nil", "[1, 2, 3] == []", "len([]) > 0",
  "Any matches Any", "!Any.Things.Contains.Any", "!ArrayOfAny[0].next.goes['any thing']",
  "ArrayOfFoo[0].Bar.Baz == ''", "ArrayOfFoo[0:10][0].Bar.Baz == ''", "!ArrayOfAny[Any]",
  "Bool && Any", "FuncParam(true, 1, 'str')", "FuncParamAny(nil)", "!Fast(Any, String)",
  "Foo.Bar == MapOfAny.id.Bar", "Foo.Bar.Baz == ''", "MapOfFoo['any'].Bar.Baz == ''",
  "Func() == 0", "FuncFoo(Foo) > 1", "Any() > 0", "Embed.EmbedString == ''", "EmbedString == ''",
  "EmbedMethod(0) == ''", "Embed.EmbedString == ''", "EmbedString == ''", "{id: Foo.Bar.Baz, 'str': String} == {}",
  "Variadic(0, 1, 2) || Variadic(0)", "count(1..30, {# % 3 == 0}) > 0", "map(1..3, {#}) == [1,2,3]",
  "map(1..3, #index) == [0,1,2]", "map(filter(ArrayOfFoo, {.Bar.Baz != ''}), {.Bar}) == []",
  "Time == Time", "Any == Time", "Any != Time", "Any > Time", "Any >= Time", "Any < Time",
  "Any <= Time", "Any - Time > Duration", "Any == Any", "Any != Any", "Any > Any",
  "Any >= Any", "Any < Any", "Any <= Any", "Any - Any < Duration", "Time == Any",
  "Time != Any", "Time > Any", "Time >= Any", "Time < Any", "Time <= Any", "Time - Any == Duration",
  "Time + Duration == Time", "Duration + Time == Time", "Duration + Any == Time",
  "Any + Duration == Time", "Any.A?.B == nil", "(Any.Bool ?? Bool) > 0", "Bool ?? Bool",
  "let foo = 1; foo == 1", "(Embed).EmbedPointerEmbedInt > 0", "(true ? [1] : [[1]])[0][0] == 1",
]

///|
test "checker compile-ok table: expr TestCheck rows compile" {
  let fails = StringBuilder::new()
  let mut ran = 0
  for row in check_ok_rows {
    // TestCheck asserts the CHECKER accepts these programs — the row
    // is never executed. mbel's checked compile = check + lower.
    let r = try? @expr.compile_expr_checked_limited(row, 0)
    match r {
      Ok(_) => ran += 1
      Err(@evaluator.EvalErr(m)) =>
        fails.write_string("ERR: " + row + " : " + m + "\n")
      Err(_) => fails.write_string("ERR: " + row + "\n")
    }
  }
  if fails.to_string() != "" {
    inspect("ran=" + ran.to_string() + "\n" + fails.to_string(), content="")
  }
}
