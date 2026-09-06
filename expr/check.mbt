// SPDX-License-Identifier: Apache-2.0
// mbel expr package — static checker (stage 4.4.4, phase 1).
//
// expr-lang has two execution modes: `Eval` (parser + compiler only,
// no type checking — runtime panics on kind mismatches) and `Compile`
// (checker runs first, type errors surface as compile errors). mbel's
// `eval_expr` mirrors the Eval mode and stays untouched; this checker
// mirrors the Compile mode and is wired into the strict entry points
// (`check_expr`, `compile_expr_checked_*`, `Engine::eval_expr_checked`).
//
// Phase 1 scope (per the review roadmap): basic operator type rules on
// statically-known operand natures (literals and their propagation),
// with expr's compile-mode error messages. Full Nature inference over
// containers/functions and env whitelists is phase 2.

///|
pub(all) suberror CheckError {
  CheckErr(String)
}

///|
/// Static nature of an expression: what the checker can prove about
/// its type without an environment. Unknown = dynamic (env values).
pub(all) enum Nature {
  IntN
  FloatN
  StringN
  BoolN
  NilN
  UnknownN
} derive(Eq, Debug)

///|
/// expr's compile-mode type names.
pub fn nature_name(n : Nature) -> String {
  match n {
    IntN => "int"
    FloatN => "float"
    StringN => "string"
    BoolN => "bool"
    NilN => "nil"
    UnknownN => "dynamic"
  }
}

///|
fn is_number(n : Nature) -> Bool {
  n is IntN || n is FloatN
}

///|
/// Type-checks a parsed expr AST. Raises CheckError on the first
/// violation with expr's compile-mode message wording.
pub fn check(n : ENode) -> Unit raise CheckError {
  ignore(infer(n))
}

///|
/// Infers the static nature of a node, checking its children.
fn infer(n : ENode) -> Nature raise CheckError {
  match n {
    ENil => NilN
    EBool(_) => BoolN
    EInt(_) => IntN
    EFloat(_) => FloatN
    EStr(_) | EBytes(_) => StringN
    EIdent(_) => UnknownN
    EPointer(_) => UnknownN
    EMember(base, _, _) => {
      ignore(infer(base))
      UnknownN
    }
    EIndex(base, idx) => {
      ignore(infer(base))
      ignore(infer(idx))
      UnknownN
    }
    ESlice(base, f, t) => {
      ignore(infer(base))
      match f {
        Some(x) => ignore(infer(x))
        None => ()
      }
      match t {
        Some(x) => ignore(infer(x))
        None => ()
      }
      UnknownN
    }
    EArray(items) => {
      for x in items {
        ignore(infer(x))
      }
      UnknownN
    }
    EMap(pairs) => {
      for kv in pairs {
        let (k, v) = kv
        ignore(infer(k))
        ignore(infer(v))
      }
      UnknownN
    }
    ECall(callee, args) => {
      ignore(infer(callee))
      for a in args {
        ignore(infer(a))
      }
      UnknownN
    }
    EPred(inner) => infer(inner)
    EUnary(op, x) => {
      let t = infer(x)
      match op {
        "not" | "!" =>
          match t {
            // expr requires boolean operands for !/not when known
            BoolN | UnknownN => BoolN
            other =>
              raise CheckError::CheckErr(
                "invalid operation: ! (mismatched type " +
                nature_name(other) +
                ")",
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
              )
          }
        _ => UnknownN
      }
    }
    EBinary(op, l, r) => check_binary(op, l, r)
    ECond(t, c, a) => {
      let tt = infer(t)
      match tt {
        BoolN | UnknownN => ()
        other =>
          raise CheckError::CheckErr(
            "non-bool expression (type " +
            nature_name(other) +
            ") used as condition",
          )
      }
      match c {
        Some(x) => ignore(infer(x))
        None => ()
      }
      match a {
        Some(x) => ignore(infer(x))
        None => ()
      }
      UnknownN
    }
    ELet(name, v, rest) => {
      ignore(infer(v))
      // let bindings get the inferred nature of their initializer
      // (phase 2 adds a scope; phase 1 re-infers identifiers as
      // dynamic, so name uses are not statically typed yet)
      ignore(name)
      infer(rest)
    }
    ESeq(items) => {
      let mut last = UnknownN
      for x in items {
        last = infer(x)
      }
      last
    }
  }
}

///|
fn check_binary(op : String, l : ENode, r : ENode) -> Nature raise CheckError {
  let lt = infer(l)
  let rt = infer(r)
  let lname = nature_name(lt)
  let rname = nature_name(rt)
  match op {
    "+" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) => FloatN
        (StringN, StringN) => StringN
        // dynamic sides may resolve at runtime; known mismatches error
        (UnknownN, _) | (_, UnknownN) => UnknownN
        (NilN, NilN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: + (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "-" | "*" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) => FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: " +
            op +
            " (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "/" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: / (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "%" =>
      match (lt, rt) {
        (IntN, IntN) => IntN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: % (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    ".." =>
      match (lt, rt) {
        (IntN, IntN) => UnknownN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: .. (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "==" | "!=" =>
      match (lt, rt) {
        // numerics mix; nil compares with anything; strings with strings
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          BoolN
        (StringN, StringN) | (BoolN, BoolN) | (NilN, NilN) => BoolN
        (NilN, _) | (_, NilN) => BoolN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: " +
            op +
            " (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "<" | ">" | "<=" | ">=" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          BoolN
        (StringN, StringN) => BoolN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: " +
            op +
            " (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "&&" | "||" | "and" | "or" =>
      match (lt, rt) {
        (BoolN, BoolN) => BoolN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: " +
            op +
            " (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "**" | "^" =>
      match (lt, rt) {
        (IntN, IntN) | (IntN, FloatN) | (FloatN, IntN) | (FloatN, FloatN) =>
          FloatN
        (UnknownN, _) | (_, UnknownN) => UnknownN
        _ =>
          raise CheckError::CheckErr(
            "invalid operation: " +
            op +
            " (mismatched types " +
            lname +
            " and " +
            rname +
            ")",
          )
      }
    "in" | "matches" | "contains" | "startsWith" | "endsWith" => UnknownN
    "??" => UnknownN
    "|" => UnknownN // pipe never survives as a binary node
    _ => UnknownN
  }
}
