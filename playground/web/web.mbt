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
/// Runs `f` against a fresh engine instance (dialect demo transforms
/// registered, execution engine selected) and the parsed env JSON,
/// canonicalizing the result or formatting the error for the page.
fn with_env(
  env : String,
  engine : String,
  f : (@engine.Engine, @ast.Value) -> @ast.Value raise @engine.EngineError,
) -> String {
  let ctx = json_to_value(@json.parse(env)) catch {
    _ => return error_out("env is not valid JSON")
  }
  let inst = @engine.new()
  register_demo_transforms(inst)
  if engine == "vm" {
    @engine.Engine::set_engine(inst, Vm)
  }
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
/// Classic dialect (JS semantics) — the locked-corpus entry.
pub fn eval_jexl(expr : String, env : String, engine : String) -> String {
  with_env(env, engine, (inst, ctx) => @engine.Engine::eval(inst, expr, ctx))
}

///|
/// Standard dialect, Eval mode — dynamic typed runtime errors.
pub fn eval_expr(expr : String, env : String, engine : String) -> String {
  with_env(env, engine, (inst, ctx) => {
    @engine.Engine::eval_expr(inst, expr, ctx)
  })
}

///|
/// Standard dialect, Compile mode — static checker errors.
pub fn eval_checked(expr : String, env : String, engine : String) -> String {
  with_env(env, engine, (inst, ctx) => {
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

///|
/// A user function parsed from a functions file (format v1).
struct UserFnSpec {
  name : String
  params : Array[String]?
  body : String
  description : String
}

///|
/// Validates a functions file (format v1) and returns the parsed
/// specs. Known top-level keys: `version` (must be 1), `functions`
/// (array), `env` (object — a page-level example, ignored by the
/// engine). Known function keys: `name`, `params`, `body`,
/// `description`; unknown keys are rejected as likely typos. Errors
/// carry the `functions[i]` index.
fn parse_user_functions(j : Json) -> Result[Array[UserFnSpec], String] {
  let obj = match j {
    Object(m) => m
    _ => return Err("functions file must be a JSON object")
  }
  let mut version = 0.0
  let mut seen_version = false
  let mut funcs : Array[Json] = []
  let mut seen_funcs = false
  for kv in obj.to_array() {
    let (k, v) = kv
    match k {
      "version" =>
        match v {
          Number(d, ..) => {
            version = d
            seen_version = true
          }
          _ => return Err("functions file: \"version\" must be a number")
        }
      "functions" =>
        match v {
          Array(xs) => {
            funcs = xs
            seen_funcs = true
          }
          _ => return Err("functions file: \"functions\" must be an array")
        }
      // page-level example environment; the engine ignores it
      "env" =>
        match v {
          Object(_) => ()
          _ => return Err("functions file: \"env\" must be an object")
        }
      _ => return Err("functions file: unknown field \"" + k + "\"")
    }
  }
  if !seen_version {
    return Err("functions file: missing \"version\"")
  }
  if version != 1.0 {
    return Err("functions file: unsupported version " + version.to_string())
  }
  if !seen_funcs {
    return Err("functions file: missing \"functions\"")
  }
  let specs : Array[UserFnSpec] = []
  for i in 0..<funcs.length() {
    let fo = match funcs[i] {
      Object(m) => m
      _ => return Err("functions[" + i.to_string() + "]: must be an object")
    }
    let mut name = ""
    let mut params : Array[String]? = None
    let mut body = ""
    let mut description = ""
    let mut has_name = false
    let mut has_body = false
    for kv in fo.to_array() {
      let (k, v) = kv
      match k {
        "name" =>
          match v {
            String(s) => {
              name = s
              has_name = true
            }
            _ =>
              return Err(
                "functions[" + i.to_string() + "]: \"name\" must be a string",
              )
          }
        "params" =>
          match v {
            Array(xs) => {
              let ps : Array[String] = []
              for pi in 0..<xs.length() {
                match xs[pi] {
                  String(s) => ps.push(s)
                  _ =>
                    return Err(
                      "functions[" +
                      i.to_string() +
                      "]: \"params\" must be an array of strings",
                    )
                }
              }
              params = Some(ps)
            }
            _ =>
              return Err(
                "functions[" +
                i.to_string() +
                "]: \"params\" must be an array of strings",
              )
          }
        "body" =>
          match v {
            String(s) => {
              body = s
              has_body = true
            }
            _ =>
              return Err(
                "functions[" + i.to_string() + "]: \"body\" must be a string",
              )
          }
        "description" =>
          match v {
            String(s) => description = s
            _ =>
              return Err(
                "functions[" +
                i.to_string() +
                "]: \"description\" must be a string",
              )
          }
        _ =>
          return Err(
            "functions[" + i.to_string() + "]: unknown field \"" + k + "\"",
          )
      }
    }
    if !has_name {
      return Err("functions[" + i.to_string() + "]: missing \"name\"")
    }
    if !has_body {
      return Err("functions[" + i.to_string() + "]: missing \"body\"")
    }
    specs.push({ name, params, body, description })
  }
  Ok(specs)
}

///|
/// Validates a functions file and returns the resolved signature list
/// `[{"name":...,"params":[...],"description":...}]` — params are the
/// explicit list or auto-extracted from the body (first-appearance
/// order). Page-facing: used to render the function chips.
pub fn describe_functions(funcs_json : String) -> String {
  let fj = @json.parse(funcs_json) catch {
    _ => return error_out("functions file is not valid JSON")
  }
  let specs = match parse_user_functions(fj) {
    Ok(specs) => specs
    Err(msg) => return error_out(msg)
  }
  let out = StringBuilder::new()
  out.write_string("[")
  let mut first = true
  for sp in specs {
    if !first {
      out.write_string(",")
    }
    first = false
    let ps = match sp.params {
      Some(ps) => ps
      None =>
        @engine.user_function_params(sp.name, sp.body) catch {
          @engine.EngineErr(m) => return error_out(m)
        }
    }
    out.write_string("{\"name\":")
    out.write_string(canon_str(sp.name))
    out.write_string(",\"params\":[")
    out.write_string(ps.map(fn(p) { canon_str(p) }).join(","))
    out.write_string("],\"description\":")
    out.write_string(canon_str(sp.description))
    out.write_string("}")
  }
  out.write_string("]")
  out.to_string()
}

///|
/// Evaluates with user functions loaded from a functions file (format
/// v1). `mode` selects the dialect entry — "eval" (standard, default),
/// "checked" (standard, strict), "legacy" (classic); `engine` selects
/// "walk" (default) or "vm". The evaluation env doubles as the
/// functions' default bindings: unpassed parameters fall back to
/// same-named env keys, explicit arguments win. All failures (file
/// format, registration, evaluation) return {"$error": "..."}.
pub fn eval_with_functions(
  expr : String,
  env : String,
  funcs_json : String,
  mode : String,
  engine : String,
) -> String {
  let ctx = json_to_value(@json.parse(env)) catch {
    _ => return error_out("env is not valid JSON")
  }
  let fj = @json.parse(funcs_json) catch {
    _ => return error_out("functions file is not valid JSON")
  }
  let specs = match parse_user_functions(fj) {
    Ok(specs) => specs
    Err(msg) => return error_out(msg)
  }
  let inst = @engine.new()
  register_demo_transforms(inst)
  if engine == "vm" {
    @engine.Engine::set_engine(inst, Vm)
  }
  let defs : Array[@engine.UserFunctionDef] = []
  for sp in specs {
    defs.push({ name: sp.name, params: sp.params, body: sp.body })
  }
  // non-object envs simply provide no default bindings
  let defaults : @ast.Value? = match ctx {
    @ast.ObjectVal(_) => Some(ctx)
    _ => None
  }
  let registered = @engine.Engine::add_expression_functions(
    inst, defs, defaults,
  ) catch {
    @engine.EngineErr(m) => return error_out(m)
  }
  ignore(registered)
  let v = try {
    if mode == "checked" {
      @engine.Engine::eval_expr_checked(inst, expr, ctx)
    } else if mode == "legacy" {
      @engine.Engine::eval(inst, expr, ctx)
    } else {
      @engine.Engine::eval_expr(inst, expr, ctx)
    }
  } catch {
    @engine.EngineErr(m) => return error_out(m)
  }
  canon(v)
}
