// SPDX-License-Identifier: Apache-2.0
// mbel engine package — expression-defined user functions.
//
// A UserFunctionDef registers a closure compiled from an expr source
// body, so callers can extend an instance without writing MoonBit:
// `{"name":"tax","params":["price","rate"],"body":"price * rate"}` at
// the JSON layer (playground/web). Bodies are compiled with the expr
// front end (standard dialect), constant-folded once, and dispatched
// like any other evaluation on the owning instance (Walk tree-walk or
// Vm with a per-function cached program). Each function is registered
// into BOTH pools so `f(x)`, standard-dialect pipes `x | f()` and
// classic-dialect pipes `x | f` all resolve.

///|
/// A user function definition: `name`, optional explicit `params`
/// (None = auto-extract the body's free identifiers in
/// first-appearance order), and the `body` expression source
/// (standard dialect).
pub(all) struct UserFunctionDef {
  name : String
  params : Array[String]?
  body : String
}

///|
/// Keyword names that cannot be function or parameter names — keep in
/// sync with the expr lexer's keyword_or_ident table (expr/lexer.mbt).
fn is_userfn_keyword(name : String) -> Bool {
  match name {
    "and"
    | "or"
    | "not"
    | "in"
    | "matches"
    | "contains"
    | "startsWith"
    | "endsWith"
    | "let"
    | "if"
    | "else"
    | "true"
    | "false"
    | "nil" => true
    _ => false
  }
}

///|
/// Identifier rules mirror the expr lexer (is_ident_start/is_ident_cont):
/// first character is an ASCII or Latin-1 letter, `_` or `$`;
/// continuation adds ASCII digits.
fn is_userfn_ident_start(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '_' ||
  c == '$' ||
  (c >= '\u{C0}' && c <= '\u{D6}') ||
  (c >= '\u{D8}' && c <= '\u{F6}') ||
  (c >= '\u{F8}' && c <= '\u{FF}')
}

///|
fn is_userfn_ident(name : String) -> Bool {
  if name.length() == 0 {
    return false
  }
  let chars = name.to_array()
  if !is_userfn_ident_start(chars[0]) {
    return false
  }
  for i in 1..<chars.length() {
    let c = chars[i]
    if !is_userfn_ident_start(c) && !(c >= '0' && c <= '9') {
      return false
    }
  }
  true
}

///|
fn validate_userfn_name(name : String) -> Unit raise EngineError {
  if !is_userfn_ident(name) {
    raise EngineError::EngineErr("invalid function name \"" + name + "\"")
  }
  if is_userfn_keyword(name) {
    raise EngineError::EngineErr("function name \"" + name + "\" is a keyword")
  }
  if name == "$env" {
    raise EngineError::EngineErr("function name \"$env\" is reserved")
  }
  if @grammar.is_aggregate(name) {
    raise EngineError::EngineErr(
      "function name \"" + name + "\" conflicts with an aggregate",
    )
  }
}

///|
fn validate_userfn_params(
  fname : String,
  ps : Array[String],
) -> Unit raise EngineError {
  for p in ps {
    if !is_userfn_ident(p) {
      raise EngineError::EngineErr(
        "function \"" + fname + "\": invalid parameter name \"" + p + "\"",
      )
    }
    if is_userfn_keyword(p) {
      raise EngineError::EngineErr(
        "function \"" + fname + "\": parameter name \"" + p + "\" is a keyword",
      )
    }
    if p == "$env" {
      raise EngineError::EngineErr(
        "function \"" + fname + "\": parameter name \"$env\" is reserved",
      )
    }
  }
  for i in 0..<ps.length() {
    for j in (i + 1)..<ps.length() {
      if ps[i] == ps[j] {
        raise EngineError::EngineErr(
          "function \"" +
          fname +
          "\": duplicate parameter name \"" +
          ps[i] +
          "\"",
        )
      }
    }
  }
}

///|
/// Resolves a function's parameter list: the explicit `params` when
/// given, otherwise the body's free identifiers — names that are not
/// let-bound, not call callees, not member drill-downs or relative
/// (predicate) identifiers, and not `$env` — in first-appearance
/// (left-to-right) order, deduplicated. The body is compiled with the
/// expr front end and constant-folded first, so the extracted list is
/// exactly what evaluation will look up.
pub fn user_function_params(
  name : String,
  body : String,
) -> Array[String] raise EngineError {
  validate_userfn_name(name)
  let node = @expr.compile_expr_limited(body, @parser.default_max_nodes()) catch {
    @evaluator.EvalErr(msg) =>
      raise EngineError::EngineErr("function \"" + name + "\": " + msg)
  }
  match node {
    None =>
      raise EngineError::EngineErr(
        "function \"" + name + "\": body must not be empty",
      )
    Some(n) => {
      let folded = @evaluator.constant_fold(n)
      let out : Array[String] = []
      collect_free_identifiers(folded, [], out)
      out
    }
  }
}

///|
/// Mirrors strict_names' traversal (exprapi.mbt): an identifier is
/// free when it has no drill-down root, is not relative, is not
/// `$env`, and is not bound by an enclosing let.
fn collect_free_identifiers(
  node : @ast.AstNode,
  scope : Array[String],
  out : Array[String],
) -> Unit {
  if node.node_type is @ast.VariableDeclaratorNode {
    if node.args.length() > 0 {
      collect_free_identifiers(node.args[0], scope, out)
    }
    return
  }
  if node.node_type is @ast.SequenceNode {
    let s2 = scope.copy()
    for item in node.args {
      if item.node_type is @ast.VariableDeclaratorNode {
        if item.args.length() > 0 {
          collect_free_identifiers(item.args[0], s2, out)
        }
        s2.push(item.ident_name)
      } else {
        collect_free_identifiers(item, s2, out)
      }
    }
    return
  }
  if node.node_type is @ast.IdentifierNode {
    if node.from is None &&
      !node.relative &&
      node.ident_name != "$env" &&
      !in_array(scope, node.ident_name) &&
      !in_array(out, node.ident_name) {
      out.push(node.ident_name)
    }
    return
  }
  // FunctionCall callees are names (func_name), not free identifiers;
  // arguments — predicate ones included — are walked normally.
  match node.left {
    Some(l) => collect_free_identifiers(l, scope, out)
    None => ()
  }
  match node.right {
    Some(r) => collect_free_identifiers(r, scope, out)
    None => ()
  }
  match node.cond_test {
    Some(t) => collect_free_identifiers(t, scope, out)
    None => ()
  }
  match node.consequent {
    Some(c) => collect_free_identifiers(c, scope, out)
    None => ()
  }
  match node.alternate {
    Some(a) => collect_free_identifiers(a, scope, out)
    None => ()
  }
  match node.subject {
    Some(x) => collect_free_identifiers(x, scope, out)
    None => ()
  }
  match node.filter_expr {
    Some(x) => collect_free_identifiers(x, scope, out)
    None => ()
  }
  match node.from {
    Some(x) => collect_free_identifiers(x, scope, out)
    None => ()
  }
  match node.slice_from {
    Some(x) => collect_free_identifiers(x, scope, out)
    None => ()
  }
  match node.slice_to {
    Some(x) => collect_free_identifiers(x, scope, out)
    None => ()
  }
  for x in node.array_value {
    collect_free_identifiers(x, scope, out)
  }
  for kv in node.obj_value {
    let (_, v) = kv
    collect_free_identifiers(v, scope, out)
  }
  for x in node.args {
    collect_free_identifiers(x, scope, out)
  }
}

///|
/// Builds a function body's context: the `defaults` object's pairs
/// (fallback bindings, typically the evaluation env) overridden by the
/// positional arguments' parameter names. Parameters beyond the given
/// arguments keep their defaults binding when present; parameters with
/// no argument and no default are absent — identifier lookup then
/// yields undefined, like expr.
fn userfn_context(
  params : Array[String],
  args : Array[@ast.Value],
  defaults : @ast.Value?,
) -> @ast.Value {
  let pairs : Array[(String, @ast.Value)] = match defaults {
    Some(@ast.ObjectVal(ps)) => ps.copy()
    _ => []
  }
  let n = if params.length() < args.length() {
    params.length()
  } else {
    args.length()
  }
  for i in 0..<n {
    let key = params[i]
    let mut found = false
    for j in 0..<pairs.length() {
      let (k, _) = pairs[j]
      if k == key {
        pairs[j] = (key, args[i])
        found = true
        break
      }
    }
    if !found {
      pairs.push((key, args[i]))
    }
  }
  @ast.ObjectVal(pairs)
}

///|
/// The registered callback: rebuilds the body context per call and
/// dispatches on the instance's current engine mode, exactly like
/// Expression::eval — Walk runs a fresh limited tree-walk evaluator;
/// Vm compiles the folded body to bytecode once (one-slot cache) and
/// reuses the program. Errors carry the function name as prefix.
fn make_userfn_closure(
  engine : Engine,
  name : String,
  params : Array[String],
  body : @ast.AstNode,
  defaults : @ast.Value?,
) -> Fn {
  let params = params.copy()
  // Vm program cache: a one-slot cell (arrays are shared by
  // reference), compiled against the instance grammar at first call.
  let program_cache : Array[@evaluator.Program] = []
  fn(args : Array[@ast.Value]) -> @ast.Value raise @evaluator.EvalError {
    let ctx = userfn_context(params, args, defaults)
    let result = try {
      match engine.engine {
        Walk => {
          let ev = @evaluator.new_evaluator_limited(
            engine.grammar,
            ctx,
            engine.max_depth,
            engine.max_steps,
          )
          ev.eval(body)
        }
        Vm => {
          let prog = if program_cache.is_empty() {
            let p = @evaluator.compile_program(body, engine.grammar)
            program_cache.push(p)
            p
          } else {
            program_cache[0]
          }
          @evaluator.run_program(
            prog,
            engine.grammar,
            ctx,
            engine.max_depth,
            engine.max_steps,
          )
        }
      }
    } catch {
      @evaluator.EvalErr(msg) =>
        raise @evaluator.EvalError::EvalErr("function \"" + name + "\": " + msg)
    }
    result
  }
}

///|
/// Registers expression-defined user functions on this instance.
/// Validation is atomic: names are checked first (identifier syntax,
/// not a keyword, not `$env`, not an aggregate name, unique within
/// `defs`, parameter names valid and unique), then every body is
/// compiled — a failure anywhere raises and nothing is registered.
///
/// Aggregate names are rejected because call dispatch routes them to
/// the aggregate machinery before any pool lookup, so such a
/// registration could never be called. Ordinary builtin names may be
/// overridden (upsert, mirroring `add_function`).
///
/// `defaults` supplies fallback bindings for parameters the caller did
/// not pass: the body context is the `defaults` object's pairs
/// overridden by the positional arguments' parameter names. Pass None
/// for purely lexical parameters (unpassed parameters evaluate as
/// undefined). The playground passes the evaluation environment so a
/// body like `price * rate` can run as `tax()` against the env.
///
/// Returns the resolved `(name, params)` pairs in definition order.
pub fn Engine::add_expression_functions(
  self : Engine,
  defs : Array[UserFunctionDef],
  defaults : @ast.Value?,
) -> Array[(String, Array[String])] raise EngineError {
  match defaults {
    Some(@ast.ObjectVal(_)) | None => ()
    Some(_) =>
      raise EngineError::EngineErr("function env defaults must be an object")
  }
  // phase 1: validate names and parameter lists
  let names : Array[String] = []
  for def in defs {
    validate_userfn_name(def.name)
    for other in names {
      if other == def.name {
        raise EngineError::EngineErr(
          "duplicate function name \"" + def.name + "\"",
        )
      }
    }
    names.push(def.name)
    match def.params {
      Some(ps) => validate_userfn_params(def.name, ps)
      None => ()
    }
  }
  // phase 2: compile bodies and resolve parameter lists
  let closures : Array[(String, Fn)] = []
  let resolved : Array[(String, Array[String])] = []
  for def in defs {
    let node = @expr.compile_expr_limited(def.body, self.max_nodes) catch {
      @evaluator.EvalErr(msg) =>
        raise EngineError::EngineErr("function \"" + def.name + "\": " + msg)
    }
    let folded = match node {
      Some(n) => @evaluator.constant_fold(n)
      None =>
        raise EngineError::EngineErr(
          "function \"" + def.name + "\": body must not be empty",
        )
    }
    let params = match def.params {
      Some(ps) => ps
      None => {
        let out : Array[String] = []
        collect_free_identifiers(folded, [], out)
        out
      }
    }
    closures.push(
      (def.name, make_userfn_closure(self, def.name, params, folded, defaults)),
    )
    resolved.push((def.name, params))
  }
  // phase 3: register into both pools (functions + transforms)
  for pair in closures {
    let (name, f) = pair
    upsert_fn(self.grammar.functions, name, f)
    upsert_fn(self.grammar.transforms, name, f)
  }
  resolved
}
