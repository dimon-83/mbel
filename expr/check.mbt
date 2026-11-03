// SPDX-License-Identifier: Apache-2.0
// mbel expr package — static checker (stage 4.4.4).
//
// expr-lang has two execution modes: `Eval` (parser + compiler only,
// no type checking — runtime panics on kind mismatches) and `Compile`
// (checker runs first, type errors surface as compile errors). mbel's
// `eval_expr` mirrors the Eval mode and stays untouched; this checker
// mirrors the Compile mode and is wired into the strict entry points
// (`compile_expr_checked_*`, `Engine::eval_expr_checked`).
//
// Scope: operator type rules on statically-known operand natures
// (literals, their propagation, let bindings, homogeneous container
// elements), plus static argument checks for the core builtins. Error
// messages follow expr's compile-mode wording. Env values, dynamic
// members and heterogeneous containers stay unknown/legal.
//
// Checked user-function registration (P2) adds a second context: the
// body's parameters are its only lexical bindings, and the complete
// symbol table (every function in the batch plus the instance's
// callables) is known before checking — so unknown names, unknown
// calls, and arity mismatches are compile errors rather than runtime
// surprises, including forward references.

///|
pub(all) suberror CheckError {
  // position of the offending construct (1-based line/col; EBinary =
  // its operator token), formatted by the checked entry with expr's
  // "msg (L:C)\n | src\n | ^" layout
  CheckErr(String, Int, Int)
}

///|
/// Static nature of an expression: what the checker can prove about
/// its type without an environment. Unknown = dynamic (env values).
pub(all) enum Nature {
  IntN
  FloatN
  StringN
  // byte strings (expr []byte, Go type name []uint8)
  BytesN
  BoolN
  NilN
  // homogeneous containers: element nature known
  ArrN(Nature)
  MapN(Nature)
  UnknownN
} derive(Eq, Debug)

///|
/// expr's compile-mode type names.
pub fn nature_name(n : Nature) -> String {
  match n {
    IntN => "int"
    FloatN => "float"
    StringN => "string"
    BytesN => "[]uint8"
    BoolN => "bool"
    NilN => "nil"
    ArrN(t) => "[]" + nature_name(t)
    MapN(t) => "map[" + nature_name(t) + "]"
    UnknownN => "dynamic"
  }
}

///|
fn known(n : Nature) -> Bool {
  match n {
    UnknownN => false
    ArrN(UnknownN) | MapN(UnknownN) => false
    _ => true
  }
}

///|
/// expr's `ComparableTo`, restricted to the natures mbel has: unknown and
/// nil are comparable with anything, numbers with numbers (int/float mix
/// included), arrays with arrays, and otherwise the families must match.
/// Used by the `in` membership check (`1 in ["a"]` is a compile error in
/// expr, not a silent `false`).
fn nature_comparable(l : Nature, r : Nature) -> Bool {
  match (l, r) {
    (UnknownN, _) | (_, UnknownN) => true
    (NilN, _) | (_, NilN) => true
    (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) => true
    (ArrN(_), ArrN(_)) => true
    (MapN(_), MapN(_)) => true
    (StringN, StringN) | (BoolN, BoolN) | (BytesN, BytesN) => true
    _ => false
  }
}

///|
/// expr's `AssignableTo` for the natures mbel has — used by the map-key
/// half of the `in` check. Note the difference from `nature_comparable`:
/// `nil` is comparable with anything but is *not* assignable to a string
/// key, so `nil in {a: 1}` is a compile error in expr.
fn nature_assignable(l : Nature, target : Nature) -> Bool {
  match (l, target) {
    (UnknownN, _) | (_, UnknownN) => true
    (StringN, StringN) | (IntN, IntN) | (FloatN, FloatN) | (BoolN, BoolN) =>
      true
    (BytesN, BytesN) | (ArrN(_), ArrN(_)) | (MapN(_), MapN(_)) => true
    _ => false
  }
}

///|
type Scope = Array[(String, Nature)]

///|
/// Call-resolution context threaded through the checker. The lenient
/// context is the historical behaviour: bare identifiers may come from
/// the environment and unknown calls surface at runtime. Checked
/// user-function registration turns both strict flags on once the whole
/// symbol table (the batch plus the instance's callables) is built.
pub(all) struct CheckCtx {
  // exact arity of every registered user function, by name
  functions : Array[(String, Int)]
  // names callable in the standard dialect (instance pool functions)
  callables : Array[String]
  // reject identifiers that are neither bound nor `$env`
  strict_names : Bool
  // reject calls to names outside `callables`/aggregates
  strict_calls : Bool
}

///|
fn lenient_ctx() -> CheckCtx {
  { functions: [], callables: [], strict_names: false, strict_calls: false, }
}

///|
fn in_names(names : Array[String], name : String) -> Bool {
  for n in names {
    if n == name {
      return true
    }
  }
  false
}

///|
fn find_arity(functions : Array[(String, Int)], name : String) -> Int? {
  for pair in functions {
    let (n, arity) = pair
    if n == name {
      return Some(arity)
    }
  }
  None
}

///|
/// Whether a standard-dialect call may resolve at runtime: a registered
/// user function (exact arity known), an instance-pool function, or an
/// aggregate (intercepted before the pool lookup).
fn is_known_callable(name : String, ctx : CheckCtx) -> Bool {
  find_arity(ctx.functions, name) is Some(_) ||
  in_names(ctx.callables, name) ||
  @grammar.is_aggregate(name)
}

///|
/// Type-checks a parsed expr AST. Raises CheckError on the first
/// violation with expr's compile-mode message wording.
pub fn check(n : ENode) -> Unit raise CheckError {
  check_with_ctx(n, lenient_ctx())
}

///|
/// Type-checks with an explicit call-resolution context (see
/// `CheckCtx`). Strictness only affects identifiers and calls; operator
/// and builtin argument rules are unchanged.
pub fn check_with_ctx(n : ENode, ctx : CheckCtx) -> Unit raise CheckError {
  ignore(infer(n, [], ctx))
}

///|
/// Type-checks a user-function body (P2). The parameter list — explicit
/// or auto-extracted — is the body's lexical scope, so an identifier
/// that is neither a parameter, a let binding, nor `$env` is an unknown
/// name; calls must target a function in `functions`/`callables` or an
/// aggregate, with exact arity for the former. Both strict flags are on.
pub fn check_function_body(
  n : ENode,
  params : Array[String],
  functions : Array[(String, Int)],
  callables : Array[String],
) -> Unit raise CheckError {
  let scope : Scope = params.map(fn(p) { (p, UnknownN) })
  let ctx : CheckCtx = {
    functions,
    callables,
    strict_names: true,
    strict_calls: true,
  }
  ignore(infer(n, scope, ctx))
}

///|
fn scope_get(scope : Scope, name : String) -> Nature? {
  let mut i = scope.length() - 1
  while i >= 0 {
    let (n, t) = scope[i]
    if n == name {
      return Some(t)
    }
    i -= 1
  }
  None
}

///|
/// Infers the static nature of a node under a let scope.
fn infer(n : ENode, scope : Scope, ctx : CheckCtx) -> Nature raise CheckError {
  match n {
    ENil(_, _) => NilN
    EBool(_, _, _) => BoolN
    EInt(_, _, _) => IntN
    EFloat(_, _, _) => FloatN
    EStr(_, _, _) => StringN
    EBytes(_, _, _) => BytesN
    EIdent(name, line, col) =>
      match scope_get(scope, name) {
        Some(t) => t
        None => {
          // `$env` is the documented escape hatch for environment reads;
          // it is never an unknown name.
          if ctx.strict_names && name != "$env" {
            raise CheckError::CheckErr("unknown name " + name, line, col)
          }
          UnknownN
        }
      }
    EPointer(_, _, _) => UnknownN
    EMember(base, _, _, _, _) => {
      ignore(infer(base, scope, ctx))
      UnknownN
    }
    EIndex(base, idx, _, _) => {
      ignore(infer(base, scope, ctx))
      ignore(infer(idx, scope, ctx))
      UnknownN
    }
    ESlice(base, f, t, _, _) => {
      ignore(infer(base, scope, ctx))
      match f {
        Some(x) => ignore(infer(x, scope, ctx))
        None => ()
      }
      match t {
        Some(x) => ignore(infer(x, scope, ctx))
        None => ()
      }
      UnknownN
    }
    EArray(items, _, _) => {
      let mut elem = UnknownN
      let mut first = true
      for x in items {
        let t = infer(x, scope, ctx)
        if first {
          elem = t
          first = false
        } else if elem != t {
          elem = UnknownN
        }
      }
      ArrN(elem)
    }
    EMap(pairs, _, _) => {
      let mut vt = UnknownN
      let mut first = true
      for kv in pairs {
        let (_, v) = kv
        let t = infer(v, scope, ctx)
        if first {
          vt = t
          first = false
        } else if vt != t {
          vt = UnknownN
        }
      }
      MapN(vt)
    }
    ECall(callee, args, line, col) => {
      let callee_name = match callee {
        EIdent(f, _, _) => f
        _ => ""
      }
      let arity = if callee_name == "" {
        None
      } else {
        find_arity(ctx.functions, callee_name)
      }
      if callee_name != "" {
        if ctx.strict_calls && !is_known_callable(callee_name, ctx) {
          raise CheckError::CheckErr(
            "unknown function " + callee_name,
            line,
            col,
          )
        }
        // exact arity for registered user functions (explicit or
        // auto-extracted params); aggregate/builtin arity stays dynamic
        match arity {
          Some(n) =>
            if args.length() != n {
              raise CheckError::CheckErr(
                "invalid number of arguments for " +
                callee_name +
                " (expected " +
                n.to_string() +
                ", got " +
                args.length().to_string() +
                ")",
                line,
                col,
              )
            }
          None => ()
        }
      }
      // static argument checks for the core builtins (expr messages);
      // expr points the caret at the call start. User functions and
      // aggregates are exempt: their argument rules are their own.
      match arity {
        Some(_) => ()
        None =>
          if callee_name != "" && args.length() > 0 {
            let arg0 = infer(args[0], scope, ctx)
            check_builtin_arg(callee_name, arg0, line, col)
          }
      }
      // A bare callee is a name, not an identifier read: it is resolved
      // by the call checks above, never by the strict-name rule.
      match callee {
        EIdent(_, _, _) => ()
        _ => ignore(infer(callee, scope, ctx))
      }
      for a in args {
        ignore(infer(a, scope, ctx))
      }
      UnknownN
    }
    EPred(inner, _, _) => infer(inner, scope, ctx)
    EUnary(op, x, line, col) => {
      let t = infer(x, scope, ctx)
      match op {
        "not" | "!" =>
          match t {
            BoolN | UnknownN => BoolN
            other =>
              raise CheckError::CheckErr(
                "invalid operation: ! (mismatched type " +
                nature_name(other) +
                ")",
                line,
                col,
              )
          }
        "-" | "+" =>
          match t {
            IntN => IntN
            FloatN | UnknownN | NilN => FloatN
            other =>
              raise CheckError::CheckErr(
                "invalid operation: - (mismatched type " +
                nature_name(other) +
                ")",
                line,
                col,
              )
          }
        _ => UnknownN
      }
    }
    EBinary(op, l, r, line, col) =>
      check_binary(op, l, r, scope, line, col, ctx)
    ECond(t, c, a, _, _) => {
      let tt = infer(t, scope, ctx)
      match tt {
        BoolN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "non-bool expression (type " +
            nature_name(other) +
            ") used as condition",
            node_line(t),
            node_col(t),
          )
      }
      match c {
        Some(x) => ignore(infer(x, scope, ctx))
        None => ()
      }
      match a {
        Some(x) => ignore(infer(x, scope, ctx))
        None => ()
      }
      UnknownN
    }
    ELet(name, v, rest, _, _) => {
      let vt = infer(v, scope, ctx)
      // shadowing replaces the binding (Eval-mode lets redeclare)
      let scope2 = scope.copy()
      let mut replaced = false
      for i in 0..<scope2.length() {
        let (n, _) = scope2[i]
        if n == name {
          scope2[i] = (name, vt)
          replaced = true
        }
      }
      if !replaced {
        scope2.push((name, vt))
      }
      infer(rest, scope2, ctx)
    }
    ESeq(items, _, _) => {
      let mut last = UnknownN
      for x in items {
        // each item is self-contained: parse_let wraps its whole rest
        last = infer(x, scope, ctx)
      }
      last
    }
  }
}

///|
/// Static argument checks for the core builtins (expr compile-mode
/// messages).
fn check_builtin_arg(
  name : String,
  t : Nature,
  line : Int,
  col : Int,
) -> Unit raise CheckError {
  match name {
    "len" =>
      match t {
        StringN | BytesN | ArrN(_) | MapN(_) | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for len (type " + nature_name(other) + ")",
            line,
            col,
          )
      }
    "int" =>
      match t {
        IntN | FloatN | StringN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for int (type " + nature_name(other) + ")",
            line,
            col,
          )
      }
    "float" =>
      match t {
        IntN | FloatN | StringN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for float (type " + nature_name(other) + ")",
            line,
            col,
          )
      }
    "abs" | "ceil" | "floor" | "round" =>
      match t {
        IntN | FloatN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for " +
            name +
            " (type " +
            nature_name(other) +
            ")",
            line,
            col,
          )
      }
    "upper" | "lower" | "trim" | "repeat" | "indexOf" | "lastIndexOf" =>
      match t {
        StringN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for " +
            name +
            " (type " +
            nature_name(other) +
            ")",
            line,
            col,
          )
      }
    "filter"
    | "map"
    | "all"
    | "any"
    | "none"
    | "one"
    | "count"
    | "sum"
    | "find"
    | "findIndex"
    | "findLast"
    | "findLastIndex"
    | "groupBy"
    | "sortBy"
    | "reduce" =>
      match t {
        ArrN(_) | BytesN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "invalid argument for " +
            name +
            " (type " +
            nature_name(other) +
            ")",
            line,
            col,
          )
      }
    _ => ()
  }
}

///|
fn check_binary(
  op : String,
  l : ENode,
  r : ENode,
  scope : Scope,
  op_line : Int,
  op_col : Int,
  ctx : CheckCtx,
) -> Nature raise CheckError {
  let lt = infer(l, scope, ctx)
  let rt = infer(r, scope, ctx)
  let lname = nature_name(lt)
  let rname = nature_name(rt)
  fn mismatch() -> CheckError {
    CheckError::CheckErr(
      "invalid operation: " +
      op +
      " (mismatched types " +
      lname +
      " and " +
      rname +
      ")",
      op_line,
      op_col,
    )
  }
  match op {
    "+" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) => FloatN
        (StringN, StringN) => StringN
        (NilN, NilN) => UnknownN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "-" | "*" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) => FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "/" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "%" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    ".." =>
      match (lt, rt) {
        (IntN, IntN) => UnknownN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "==" | "!=" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          BoolN
        (StringN, StringN) | (BytesN, BytesN) | (BoolN, BoolN) | (NilN, NilN) =>
          BoolN
        (NilN, _) | (_, NilN) => BoolN
        // arrays are value-comparable when their element natures match
        (ArrN(a), ArrN(b)) =>
          if a == b || !known(a) || !known(b) {
            BoolN
          } else {
            raise mismatch()
          }
        (MapN(a), MapN(b)) =>
          if a == b || !known(a) || !known(b) {
            BoolN
          } else {
            raise mismatch()
          }
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "<" | ">" | "<=" | ">=" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          BoolN
        (StringN, StringN) => BoolN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "&&" | "||" | "and" | "or" =>
      match (lt, rt) {
        (BoolN, BoolN) => BoolN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    "**" | "^" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ => raise mismatch()
      }
    // expr checks membership types against the container: the array half
    // compares against the element type, the map half against the key
    // type — an AssignableTo test, not ComparableTo, because `nil` is
    // comparable with anything yet not assignable to a string key. mbel
    // maps are string-keyed by construction, so the key type is string.
    "in" =>
      match rt {
        ArrN(elem) =>
          if nature_comparable(lt, elem) {
            UnknownN
          } else {
            raise CheckError::CheckErr(
              "cannot use " +
              lname +
              " as type " +
              nature_name(elem) +
              " in array",
              op_line,
              op_col,
            )
          }
        MapN(_) =>
          if nature_assignable(lt, StringN) {
            UnknownN
          } else {
            raise CheckError::CheckErr(
              "cannot use " + lname + " as type string in map key",
              op_line,
              op_col,
            )
          }
        _ => UnknownN
      }
    "matches" | "contains" | "startsWith" | "endsWith" => UnknownN
    "??" => UnknownN
    "|" => UnknownN // pipe never survives as a binary node
    _ => UnknownN
  }
}
