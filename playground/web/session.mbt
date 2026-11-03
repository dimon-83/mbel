// SPDX-License-Identifier: Apache-2.0
// mbel playground — session handles (P2) and per-call budgets (P4).
//
// A session is one registered function set on one engine instance. Today
// `eval_with_functions` re-parses the functions file, re-resolves every
// parameter list and re-checks every body on every call; with 200
// functions that is ~0.475 ms per call, 106× a plain eval. A session
// pays that once and then evaluates against the prepared instance.
//
// Handles are instance-scoped, immutable and capped: the wasm instance is
// single-threaded, so the store is a plain array and no locking is
// implied or provided. Releasing is explicit; `eval_with_functions` stays
// exactly as it was (create + eval + release sugar) so existing hosts and
// the playground are unaffected.

///|
/// A live session: the prepared instance plus the metadata hosts need to
/// introspect it. `signatures` is the resolved `(name, params)` list in
/// definition order (params explicit or auto-extracted).
struct Session {
  id : String
  mode : String
  engine_name : String
  inst : @engine.Engine
  signatures : Array[(String, Array[String])]
}

///|
/// Session store and id sequence. Both are arrays because arrays are
/// reference values: a package-level immutable binding is enough.
let sessions : Array[Session] = []

///|
let session_seq : Array[Int32] = [0]

///|
/// Live-session cap. A misbehaving host that never releases would
/// otherwise grow the store without bound; 16 is enough for the
/// request-per-session patterns this ABI targets (raise it deliberately
/// via the limits object if a host needs more).
fn session_limit() -> Int32 {
  16
}

///|
/// Looks a handle up; None means released or never created — the caller
/// reports `HANDLE_UNKNOWN`.
fn find_session(id : String) -> Session? {
  for s in sessions {
    if s.id == id {
      return Some(s)
    }
  }
  None
}

///|
/// Removes a handle; false when it was not live.
fn drop_session(id : String) -> Bool {
  let mut i = 0
  while i < sessions.length() {
    if sessions[i].id == id {
      ignore(sessions.remove(i))
      return true
    }
    i = i + 1
  }
  false
}

///|
/// Creates a session from a functions file (format v1).
///
/// `mode` is "eval" (standard, dynamic — default semantics), "checked"
/// (standard, bodies type-checked at registration, calls arity-checked) or
/// "legacy" (classic dialect); anything else is `MODE_UNKNOWN`. `engine` is
/// "walk" or "vm"; anything else is `ENGINE_UNKNOWN`. `defaults_json` is an
/// optional JSON object supplying fallback bindings for parameters the
/// caller does not pass (empty string or "null" for none) — it plays the
/// role the evaluation env plays in `eval_with_functions`.
///
/// Creation is atomic: on any validation error nothing is registered and
/// no handle is consumed.
pub fn create_session(
  funcs_json : String,
  mode : String,
  engine : String,
  defaults_json : String,
) -> String {
  if mode != "eval" && mode != "checked" && mode != "legacy" {
    return code_out(
      "unknown mode \"" +
      mode +
      "\" (expected \"eval\", \"checked\" or \"legacy\")",
      "MODE_UNKNOWN",
    )
  }
  if engine != "walk" && engine != "vm" {
    return code_out(
      "unknown engine \"" + engine + "\" (expected \"walk\" or \"vm\")",
      "ENGINE_UNKNOWN",
    )
  }
  if sessions.length() >= session_limit() {
    return code_out(
      "session limit reached (more than " +
      session_limit().to_string() +
      " live sessions; release one first)",
      "HANDLE_LIMIT",
    )
  }
  let fj = @json.parse(funcs_json) catch {
    _ => return code_out("functions file is not valid JSON", "FUNCS_JSON")
  }
  let specs = match parse_user_functions(fj) {
    Ok(specs) => specs
    Err(msg) => return code_out(msg, functions_file_code(msg))
  }
  let defaults = session_defaults(defaults_json) catch {
    @engine.EngineErr(msg) => return code_out(msg, "ENV_JSON")
  }
  let inst = make_instance(engine)
  let defs : Array[@engine.UserFunctionDef] = []
  for sp in specs {
    defs.push({ name: sp.name, params: sp.params, body: sp.body, })
  }
  let registered = try {
    if mode == "checked" {
      @engine.Engine::add_expression_functions_checked(inst, defs, defaults)
    } else {
      @engine.Engine::add_expression_functions(inst, defs, defaults)
    }
  } catch {
    @engine.EngineErr(m) => return code_out(m, registration_code(m))
  }
  session_seq[0] = session_seq[0] + 1
  let id = "s-" + session_seq[0].to_string()
  sessions.push({ id, mode, engine_name: engine, inst, signatures: registered, })
  session_json(id)
}

///|
/// Parses the optional defaults object. An empty string or JSON `null`
/// means "no fallback bindings"; any non-object value is a host error,
/// because parameter fallback reads object keys only.
fn session_defaults(text : String) -> @ast.Value? raise @engine.EngineError {
  if text == "" || text == "null" {
    return None
  }
  let j = @json.parse(text) catch {
    _ => raise @engine.EngineErr("session defaults is not valid JSON")
  }
  let v = json_to_value(j)
  match v {
    @ast.ObjectVal(_) => Some(v)
    _ => raise @engine.EngineErr("session defaults must be a JSON object")
  }
}

///|
/// Introspection payload for a live handle.
fn session_json(id : String) -> String {
  let s = match find_session(id) {
    Some(s) => s
    None =>
      return code_out("unknown session handle \"" + id + "\"", "HANDLE_UNKNOWN")
  }
  let out = StringBuilder::new()
  out.write_string("{\"handle\":")
  out.write_string(canon_str(s.id))
  out.write_string(",\"mode\":")
  out.write_string(canon_str(s.mode))
  out.write_string(",\"engine\":")
  out.write_string(canon_str(s.engine_name))
  out.write_string(",\"functions\":[")
  let mut first = true
  for pair in s.signatures {
    let (name, params) = pair
    if !first {
      out.write_string(",")
    }
    first = false
    out.write_string("{\"name\":")
    out.write_string(canon_str(name))
    out.write_string(",\"params\":[")
    out.write_string(params.map(fn(p) { canon_str(p) }).join(","))
    out.write_string("]}")
  }
  out.write_string("],\"limits\":")
  out.write_string(live_limits_json(s.inst))
  out.write_string("}")
  out.to_string()
}

///|
/// `describe_session(handle)` — mode, engine, resolved signatures and the
/// instance's live budgets.
pub fn describe_session(handle : String) -> String {
  session_json(handle)
}

///|
/// Evaluates an expression against a session. The env is per call (it is
/// the data, not the registration); parameter defaults were bound at
/// creation time.
pub fn eval_session(handle : String, expr : String, env : String) -> String {
  let s = match find_session(handle) {
    Some(s) => s
    None =>
      return code_out(
        "unknown session handle \"" + handle + "\"",
        "HANDLE_UNKNOWN",
      )
  }
  let ctx = json_to_value(@json.parse(env)) catch {
    _ => return code_out("env is not valid JSON", "ENV_JSON")
  }
  let v = try {
    if s.mode == "checked" {
      @engine.Engine::eval_expr_checked(s.inst, expr, ctx)
    } else if s.mode == "legacy" {
      @engine.Engine::eval(s.inst, expr, ctx)
    } else {
      @engine.Engine::eval_expr(s.inst, expr, ctx)
    }
  } catch {
    @engine.EngineErr(m) => return error_out(m)
  }
  canon(v)
}

///|
/// Releases a handle. Idempotent in the sense that the *instance* keeps
/// working afterwards — only the handle is gone, so a second release (or
/// an eval) reports HANDLE_UNKNOWN.
pub fn release_session(handle : String) -> String {
  if drop_session(handle) {
    "{\"ok\":true}"
  } else {
    code_out("unknown session handle \"" + handle + "\"", "HANDLE_UNKNOWN")
  }
}

///|
/// Tightens a live session's budgets. Only lowering is allowed: without
/// `allowRaise`, a request above the compiled default (or 0, which
/// disables a guard) is rejected, so a misconfiguration cannot silently
/// remove the DoS protection.
pub fn configure_session(handle : String, limits_json : String) -> String {
  let s = match find_session(handle) {
    Some(s) => s
    None =>
      return code_out(
        "unknown session handle \"" + handle + "\"",
        "HANDLE_UNKNOWN",
      )
  }
  let req = match parse_limits_text(limits_json) {
    Ok(r) => r
    Err(msg) => return code_out(msg, "LIMITS_INVALID")
  }
  match apply_limits(s.inst, req) {
    Ok(_) => "{\"ok\":true,\"limits\":" + live_limits_json(s.inst) + "}"
    Err(msg) => code_out(msg, "LIMITS_INVALID")
  }
}

// ---------------------------------------------------------------------------
// Per-call budgets
// ---------------------------------------------------------------------------

///|
/// A limits request parsed from JSON. Absent keys keep the compiled
/// default; `allowRaise` opts into raising a budget above that default.
struct LimitsRequest {
  max_nodes : Int32?
  max_depth : Int32?
  max_steps : Int32?
  allow_raise : Bool
}

///|
/// Parses and validates a limits object. Only the three budgets the
/// engine exposes (`maxNodes`, `maxDepth`, `maxSteps`) plus `allowRaise`
/// are accepted; unknown keys are rejected as likely typos, mirroring the
/// functions-file policy.
fn parse_limits_text(text : String) -> Result[LimitsRequest, String] {
  let j = @json.parse(text) catch {
    _ => return Err("limits is not valid JSON")
  }
  let obj = match j {
    Object(m) => m
    _ => return Err("limits must be a JSON object")
  }
  let mut max_nodes : Int32? = None
  let mut max_depth : Int32? = None
  let mut max_steps : Int32? = None
  let mut allow_raise = false
  for kv in obj.to_array() {
    let (k, v) = kv
    match k {
      "maxNodes" =>
        match budget_value("maxNodes", v) {
          Ok(n) => max_nodes = Some(n)
          Err(msg) => return Err(msg)
        }
      "maxDepth" =>
        match budget_value("maxDepth", v) {
          Ok(n) => max_depth = Some(n)
          Err(msg) => return Err(msg)
        }
      "maxSteps" =>
        match budget_value("maxSteps", v) {
          Ok(n) => max_steps = Some(n)
          Err(msg) => return Err(msg)
        }
      "allowRaise" =>
        match v {
          True => allow_raise = true
          False => allow_raise = false
          _ => return Err("limits: \"allowRaise\" must be a boolean")
        }
      _ => return Err("limits: unknown field \"" + k + "\"")
    }
  }
  Ok({ max_nodes, max_depth, max_steps, allow_raise, })
}

///|
/// A budget must be a non-negative integer that fits Int32 (the engine's
/// budget fields are Int32; 0 disables the guard).
fn budget_value(kind : String, v : Json) -> Result[Int32, String] {
  match v {
    Number(d, ..) =>
      if d != d.floor() || d < 0.0 {
        Err("limits: " + kind + " must be a non-negative integer")
      } else if d > 2147483647.0 {
        Err("limits: " + kind + " does not fit a 32-bit budget")
      } else {
        Ok(d.to_int())
      }
    _ => Err("limits: " + kind + " must be a number")
  }
}

///|
/// Applies a request to an instance. Enforcement happens here, not in the
/// parser, so both the stateless and the session paths share one rule:
/// without `allowRaise` a budget may only go down.
fn apply_limits(
  inst : @engine.Engine,
  req : LimitsRequest,
) -> Result[Unit, String] {
  let default_nodes = @parser.default_max_nodes()
  let default_depth = @evaluator.default_max_depth()
  let default_steps = @evaluator.default_max_steps()
  let nodes = match req.max_nodes {
    Some(v) => v
    None => default_nodes
  }
  let depth = match req.max_depth {
    Some(v) => v
    None => default_depth
  }
  let steps = match req.max_steps {
    Some(v) => v
    None => default_steps
  }
  if !req.allow_raise {
    match check_lowered("maxNodes", req.max_nodes, default_nodes) {
      Err(msg) => return Err(msg)
      Ok(_) => ()
    }
    match check_lowered("maxDepth", req.max_depth, default_depth) {
      Err(msg) => return Err(msg)
      Ok(_) => ()
    }
    match check_lowered("maxSteps", req.max_steps, default_steps) {
      Err(msg) => return Err(msg)
      Ok(_) => ()
    }
  }
  @engine.Engine::set_limits(inst, nodes, depth, steps)
  Ok(())
}

///|
/// Rejects a requested budget that raises or disables a guard.
fn check_lowered(
  kind : String,
  requested : Int32?,
  default : Int32,
) -> Result[Unit, String] {
  match requested {
    None => Ok(())
    Some(v) =>
      if v == 0 {
        Err(
          "limits: " +
          kind +
          " 0 disables the guard; set allowRaise: true to do that deliberately",
        )
      } else if v > default {
        Err(
          "limits: " +
          kind +
          " " +
          v.to_string() +
          " exceeds the compiled default " +
          default.to_string() +
          "; set allowRaise: true to raise it",
        )
      } else {
        Ok(())
      }
  }
}

///|
/// `eval_with_limits(expr, env, engine, limits_json)` — the stateless
/// entry with per-call budgets. Same semantics as `eval_expr`; the
/// instance lives only for this call.
pub fn eval_with_limits(
  expr : String,
  env : String,
  engine : String,
  limits_json : String,
) -> String {
  let req = match parse_limits_text(limits_json) {
    Ok(r) => r
    Err(msg) => return code_out(msg, "LIMITS_INVALID")
  }
  let ctx = json_to_value(@json.parse(env)) catch {
    _ => return code_out("env is not valid JSON", "ENV_JSON")
  }
  let inst = make_instance(engine)
  match apply_limits(inst, req) {
    Ok(_) => ()
    Err(msg) => return code_out(msg, "LIMITS_INVALID")
  }
  let v = @engine.Engine::eval_expr(inst, expr, ctx) catch {
    @engine.EngineErr(m) => return error_out(m)
  }
  canon(v)
}

///|
/// The live budgets of an instance, in the manifest's `limits` shape.
fn live_limits_json(inst : @engine.Engine) -> String {
  let (nodes, depth, steps) = @engine.Engine::limits(inst)
  "{\"maxNodes\":" +
  nodes.to_string() +
  ",\"maxDepth\":" +
  depth.to_string() +
  ",\"maxSteps\":" +
  steps.to_string() +
  ",\"userfnDepth\":256}"
}
