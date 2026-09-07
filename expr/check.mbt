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
type Scope = Array[(String, Nature)]

///|
/// Type-checks a parsed expr AST. Raises CheckError on the first
/// violation with expr's compile-mode message wording.
pub fn check(n : ENode) -> Unit raise CheckError {
  ignore(infer(n, []))
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
fn infer(n : ENode, scope : Scope) -> Nature raise CheckError {
  match n {
    ENil(_, _) => NilN
    EBool(_, _, _) => BoolN
    EInt(_, _, _) => IntN
    EFloat(_, _, _) => FloatN
    EStr(_, _, _) => StringN
    EBytes(_, _, _) => BytesN
    EIdent(name, _, _) =>
      match scope_get(scope, name) {
        Some(t) => t
        None => UnknownN
      }
    EPointer(_, _, _) => UnknownN
    EMember(base, _, _, _, _) => {
      ignore(infer(base, scope))
      UnknownN
    }
    EIndex(base, idx, _, _) => {
      ignore(infer(base, scope))
      ignore(infer(idx, scope))
      UnknownN
    }
    ESlice(base, f, t, _, _) => {
      ignore(infer(base, scope))
      match f {
        Some(x) => ignore(infer(x, scope))
        None => ()
      }
      match t {
        Some(x) => ignore(infer(x, scope))
        None => ()
      }
      UnknownN
    }
    EArray(items, _, _) => {
      let mut elem = UnknownN
      let mut first = true
      for x in items {
        let t = infer(x, scope)
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
        let t = infer(v, scope)
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
      // static argument checks for the core builtins (expr messages);
      // expr points the caret at the call start
      if callee_name != "" && args.length() > 0 {
        let arg0 = infer(args[0], scope)
        check_builtin_arg(callee_name, arg0, line, col)
      }
      ignore(infer(callee, scope))
      for a in args {
        ignore(infer(a, scope))
      }
      UnknownN
    }
    EPred(inner, _, _) => infer(inner, scope)
    EUnary(op, x, line, col) => {
      let t = infer(x, scope)
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
    EBinary(op, l, r, line, col) => check_binary(op, l, r, scope, line, col)
    ECond(t, c, a, _, _) => {
      let tt = infer(t, scope)
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
        Some(x) => ignore(infer(x, scope))
        None => ()
      }
      match a {
        Some(x) => ignore(infer(x, scope))
        None => ()
      }
      UnknownN
    }
    ELet(name, v, rest, _, _) => {
      let vt = infer(v, scope)
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
      infer(rest, scope2)
    }
    ESeq(items, _, _) => {
      let mut last = UnknownN
      for x in items {
        // each item is self-contained: parse_let wraps its whole rest
        last = infer(x, scope)
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
) -> Nature raise CheckError {
  let lt = infer(l, scope)
  let rt = infer(r, scope)
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
    "in" | "matches" | "contains" | "startsWith" | "endsWith" => UnknownN
    "??" => UnknownN
    "|" => UnknownN // pipe never survives as a binary node
    _ => UnknownN
  }
}
