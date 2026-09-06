// mbel expression runner — evaluates Jexl expressions end to end.
//
// Usage:
//   moon run cmd/main -- "<expression>"
//   moon run cmd/main -- "<expression>" '<json-context>'
//   moon run cmd/main -- "$(cat tools/corpus.txt)"   # one expr per line
//
// Prints one canonical line per expression (see tools/README.md), or
// {"$error":true} when evaluation fails.

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: moon run cmd/main -- \"<expr>\" ['<json-context>']")
    return
  }
  let corpus = args[1]
  // Optional JSON context (argv[2]); expressions without a context
  // arg keep evaluating against an empty object.
  let context = if args.length() > 2 && args[2] != "" {
    parse_context(args[2])
  } else {
    @ast.ObjectVal([])
  }
  let inst = @engine.new()
  // argv[3] == "vm" selects the bytecode engine (argv[2] stays the
  // optional JSON context).
  if args.length() > 3 && args[3] == "vm" {
    @engine.Engine::set_engine(inst, Vm)
  }
  register_demo_transforms(inst)
  for line in corpus.split("\n") {
    if line == "" {
      continue
    }
    // A line may carry its own context: expr<TAB>{json}. The context
    // column must start with '{' so expressions containing literal
    // tabs (whitespace tests) are left intact.
    let (expr, line_ctx) = split_line_context(line.to_owned())
    let ctx = match line_ctx {
      Some(json) => parse_context(json)
      None => context
    }
    let out = canon(@engine.Engine::eval(inst, expr, ctx)) catch {
      @engine.EngineErr(_) => "{\"$error\":true}"
    }
    println(out)
  }
}

///|
/// Splits a corpus line into (expression, optional context JSON):
/// the context is the text after the first tab when it starts with '{'.
fn split_line_context(line : String) -> (String, String?) {
  let chars = line.to_array()
  for i in 0..<chars.length() {
    if chars[i] == '\t' && i + 1 < chars.length() && chars[i + 1] == '{' {
      let expr = line[:i].to_owned()
      let ctx = line[i + 1:].to_owned()
      return (expr, Some(ctx))
    }
  }
  (line, None)
}

///|
/// Parses a JSON object string into a context Value. Aborts with a
/// hint when the JSON is invalid.
fn parse_context(s : String) -> @ast.Value {
  let json_val = @json.parse(s) catch {
    _ => abort("context is not valid JSON: " + s)
  }
  json_to_value(json_val)
}

///|
/// Converts a parsed Json value into an engine Value. JSON null maps
/// to NullVal, numbers to NumVal (as parsed doubles), objects to
/// ObjectVal in insertion order.
fn json_to_value(j : Json) -> @ast.Value {
  match j {
    Null => @ast.NullVal
    True => @ast.BoolVal(true)
    False => @ast.BoolVal(false)
    Number(d, ..) => @ast.NumVal(d)
    String(s) => @ast.StrVal(s)
    Array(xs) => @ast.ArrayVal(xs.map(json_to_value))
    Object(m) => {
      let pairs = m
        .to_array()
        .map(fn(kv) {
          let (k, v) = kv
          (k, json_to_value(v))
        })
      @ast.ObjectVal(pairs)
    }
  }
}

///|
/// Demo transforms shared with the differential harness (see
/// tools/jexl_driver.js) so corpus and interactive expressions behave
/// identically on both sides.
fn register_demo_transforms(inst : @engine.Engine) -> Unit {
  @engine.Engine::add_transform(inst, "dbl", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
  })
  @engine.Engine::add_transform(inst, "first", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    match args[0] {
      @ast.ArrayVal(xs) => if xs.length() > 0 { xs[0] } else { @ast.UndefVal }
      _ => @ast.UndefVal
    }
  })
  @engine.Engine::add_transform(inst, "concatWith", fn(
    args : Array[@ast.Value],
  ) -> @ast.Value {
    @evaluator.plus(args[0], args[1])
  })
}

///|
/// Canonical serializer shared with tools/jexl_driver.js — identical
/// output on both sides is what makes the corpus diff meaningful.
fn canon(v : @ast.Value) -> String {
  match v {
    @ast.BoolVal(b) => if b { "true" } else { "false" }
    @ast.NumVal(d) => canon_num(d)
    @ast.IntVal(i) => i.to_string()
    @ast.StrVal(s) => canon_str(s)
    @ast.NullVal => "null"
    @ast.UndefVal => "{\"$undef\":true}"
    @ast.ArrayVal(xs) => {
      let parts = xs.map(canon)
      "[" + parts.join(",") + "]"
    }
    @ast.ObjectVal(pairs) => {
      let parts = pairs.map(fn(kv) {
        let (k, val) = kv
        canon_str(k) + ":" + canon(val)
      })
      "{" + parts.join(",") + "}"
    }
  }
}

///|
fn canon_num(d : Double) -> String {
  if d != d {
    return "{\"$nan\":true}"
  }
  if d == 1.0 / 0.0 {
    return "{\"$inf\":true}"
  }
  if d == -1.0 / 0.0 {
    return "{\"$ninf\":true}"
  }
  d.to_string()
}

///|
/// JSON-style string escaping, matching JS JSON.stringify.
fn canon_str(s : String) -> String {
  let out = StringBuilder::new()
  out.write_char('"')
  for c in s {
    let code = c.to_int()
    match c {
      '"' => out.write_string("\\\"")
      '\\' => out.write_string("\\\\")
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_string("\\t")
      '\u{8}' => out.write_string("\\b")
      '\u{C}' => out.write_string("\\f")
      _ =>
        if code < 0x20 || code == 0x2028 || code == 0x2029 {
          out.write_string("\\u" + hex4(code))
        } else {
          out.write_char(c)
        }
    }
  }
  out.write_char('"')
  out.to_string()
}

///|
fn hex4(code : Int) -> String {
  let digits = "0123456789abcdef".to_array()
  let out = StringBuilder::new()
  for i in 0..<4 {
    let shift = (3 - i) * 4
    let nibble = (code >> shift) & 0xF
    out.write_char(digits[nibble])
  }
  out.to_string()
}
