// mbel expression runner — stage 3 differential harness client.
// Reads one expression per line from argv[1]; prints one canonical
// line per expression: the evaluated value (canonically serialized)
// or {"$error":true} when evaluation fails.

///|
fn main {
  let corpus = match @env.args() {
    arr if arr.length() > 1 => arr[1]
    _ => ""
  }
  let inst = @jexl.new_jexl()
  @jexl.Jexl::add_transform(
    inst,
    "dbl",
    fn(args : Array[@ast.Value]) -> @ast.Value {
      @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
    },
  )
  @jexl.Jexl::add_transform(
    inst,
    "first",
    fn(args : Array[@ast.Value]) -> @ast.Value {
      match args[0] {
        @ast.ArrayVal(xs) => if xs.length() > 0 { xs[0] } else { @ast.UndefVal }
        _ => @ast.UndefVal
      }
    },
  )
  @jexl.Jexl::add_transform(
    inst,
    "concatWith",
    fn(args : Array[@ast.Value]) -> @ast.Value {
      @evaluator.plus(args[0], args[1])
    },
  )
  for line in corpus.split("\n") {
    if line == "" {
      continue
    }
    let expr = line.to_owned()
    let out = try {
      canon(@jexl.Jexl::eval(inst, expr, @ast.ObjectVal([])))
    } catch {
      @jexl.JexlErr(_) => "{\"$error\":true}"
    }
    println(out)
  }
}

///|
/// Canonical serializer shared with tools/jexl_driver.js — identical
/// output on both sides is what makes the corpus diff meaningful.
fn canon(v : @ast.Value) -> String {
  match v {
    @ast.BoolVal(b) => if b { "true" } else { "false" }
    @ast.NumVal(d) => canon_num(d)
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
