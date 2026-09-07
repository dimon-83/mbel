// SPDX-License-Identifier: Apache-2.0
// mbel playground browser entry — wasm-gc exports callable from JS.
// Strings cross the boundary natively via the js-string builtins
// integration (moon.pkg link: use-js-builtin-string); on the JS side
// the module must be compiled with builtins ["js-string"] and
// importedStringConstants "_". Every entry point returns the
// canonical serializer's output, or {"$error":"..."} on failure.

///|
fn main {
  ignore(0)
}

///|
/// Runs `f` against a fresh engine instance and the parsed env JSON,
/// canonicalizing the result or formatting the error for the page.
fn with_env(
  env : String,
  f : (@engine.Engine, @ast.Value) -> @ast.Value raise @engine.EngineError,
) -> String {
  let ctx = json_to_value(@json.parse(env)) catch {
    _ => return error_out("env is not valid JSON")
  }
  let inst = @engine.new()
  register_demo_transforms(inst)
  let v = f(inst, ctx) catch { @engine.EngineErr(msg) => return error_out(msg) }
  canon(v)
}

///|
/// Demo transforms mirroring cmd/main: the legacy dialect's `|` is a
/// Jexl transform pipe, so `x | first` needs "first" registered on
/// the instance (kept in sync with the CLI's set).
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
/// Legacy Jexl dialect (JS semantics) — the locked-corpus entry.
pub fn eval_jexl(expr : String, env : String) -> String {
  with_env(env, (inst, ctx) => @engine.Engine::eval(inst, expr, ctx))
}

///|
/// expr front end, Eval mode — dynamic typed runtime errors.
pub fn eval_expr(expr : String, env : String) -> String {
  with_env(env, (inst, ctx) => @engine.Engine::eval_expr(inst, expr, ctx))
}

///|
/// expr front end, Compile mode — static checker errors.
pub fn eval_checked(expr : String, env : String) -> String {
  with_env(env, (inst, ctx) => {
    @engine.Engine::eval_expr_checked(inst, expr, ctx)
  })
}

///|
/// VM bytecode listing for the expr front end — the same lowering the
/// Vm engine executes, after constant folding. The env argument is
/// unused but kept so all page entry points share one JS signature.
pub fn disassemble(source : String, _env : String) -> String {
  let node = @expr.compile_expr_limited(source, @parser.default_max_nodes()) catch {
    @evaluator.EvalErr(msg) => return error_out(msg)
  }
  match node {
    Some(n) => {
      let prog = @evaluator.compile_program(
        @evaluator.constant_fold(n),
        @evaluator.default_grammar(),
      ) catch {
        @evaluator.EvalErr(msg) => return error_out(msg)
      }
      @evaluator.disassemble(prog)
    }
    None => error_out("Cannot disassemble an empty expression")
  }
}

///|
/// expr front-end parse-tree dump (the ENode debug representation).
pub fn dump_ast(source : String) -> String {
  let node = @expr.parse(source) catch {
    @expr.ParseErrExpr(msg, line, col) =>
      return error_out(
        "parse error at " +
        line.to_string() +
        ":" +
        col.to_string() +
        ": " +
        msg,
      )
  }
  @expr.dump(node)
}

///|
fn error_out(msg : String) -> String {
  "{\"$error\":" + canon_str(msg) + "}"
}

///|
/// Parses a JSON object string into an engine context Value. JSON
/// null maps to NullVal, numbers to NumVal (parsed doubles), objects
/// to ObjectVal in insertion order. Shared with cmd/main (kept in
/// sync — main packages cannot be imported).
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
        .map(kv => {
          let (k, v) = kv
          (k, json_to_value(v))
        })
      @ast.ObjectVal(pairs)
    }
  }
}

///|
/// Canonical serializer shared with cmd/main — identical output keeps
/// the playground consistent with the corpus driver.
fn canon(v : @ast.Value) -> String {
  match v {
    @ast.BoolVal(b) => if b { "true" } else { "false" }
    @ast.NumVal(d) => canon_num(d)
    @ast.IntVal(i) => i.to_string()
    // Bytes serialize like Go's json.Marshal of []byte (base64)
    @ast.BytesVal(b) => canon_str(@builtin.encode64_bytes(b))
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
