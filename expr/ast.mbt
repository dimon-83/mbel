// SPDX-License-Identifier: Apache-2.0
// mbel expr package — AST node set for the expr-lang dialect.
//
// Frozen per the stage-4.4 review: this node set is the contract the
// checker and the VM instruction encoding will attach to; lowering to
// the legacy AstNode is a bridge until dedicated evaluation lands.

///|
/// The expr dialect AST. Each node carries its source position
/// (1-based line/col of the construct's first token; for EBinary the
/// position of the infix OPERATOR, matching expr's caret placement).
/// Tests assert structure via dump(), which ignores positions.
pub(all) enum ENode {
  ENil(Int, Int)
  EBool(Bool, Int, Int)
  EInt(Int64, Int, Int) // decimal/hex/octal/binary, `_` separators
  // folded out
  EFloat(Double, Int, Int)
  EStr(String, Int, Int)
  EBytes(Bytes, Int, Int)
  EIdent(String, Int, Int) // identifiers and $env
  EMember(ENode, String, Bool, Int, Int) // base.name (opt for ?.name)
  EIndex(ENode, ENode, Int, Int) // base[index]
  ESlice(ENode, ENode?, ENode?, Int, Int) // base[from:to]
  ECall(ENode, Array[ENode], Int, Int) // callee(args...)
  EPred(ENode, Int, Int) // brace-wrapped/predicate-position expr
  EArray(Array[ENode], Int, Int)
  EMap(Array[(ENode, ENode)], Int, Int)
  EUnary(String, ENode, Int, Int) // ! - + not
  EBinary(String, ENode, ENode, Int, Int) // infix; pos = the operator
  ECond(ENode, ENode?, ENode?, Int, Int) // ternary ?: and if/else
  ELet(String, ENode, ENode, Int, Int) // let x = value; rest
  ESeq(Array[ENode], Int, Int) // a; b; c
  EPointer(String, Int, Int) // # / #index / #acc
}

///|
/// Node start position (1-based). EBinary reports its operator token.
pub fn node_line(n : ENode) -> Int {
  match n {
    ENil(l, _)
    | EBool(_, l, _)
    | EInt(_, l, _)
    | EFloat(_, l, _)
    | EStr(_, l, _)
    | EBytes(_, l, _)
    | EIdent(_, l, _)
    | EMember(_, _, _, l, _)
    | EIndex(_, _, l, _)
    | ESlice(_, _, _, l, _)
    | ECall(_, _, l, _)
    | EPred(_, l, _)
    | EArray(_, l, _)
    | EMap(_, l, _)
    | EUnary(_, _, l, _)
    | EBinary(_, _, _, l, _)
    | ECond(_, _, _, l, _)
    | ELet(_, _, _, l, _)
    | ESeq(_, l, _)
    | EPointer(_, l, _) => l
  }
}

///|
/// Node start column (1-based; EBinary = the operator's column).
pub fn node_col(n : ENode) -> Int {
  match n {
    ENil(_, c)
    | EBool(_, _, c)
    | EInt(_, _, c)
    | EFloat(_, _, c)
    | EStr(_, _, c)
    | EBytes(_, _, c)
    | EIdent(_, _, c)
    | EMember(_, _, _, _, c)
    | EIndex(_, _, _, c)
    | ESlice(_, _, _, _, c)
    | ECall(_, _, _, c)
    | EPred(_, _, c)
    | EArray(_, _, c)
    | EMap(_, _, c)
    | EUnary(_, _, _, c)
    | EBinary(_, _, _, _, c)
    | ECond(_, _, _, _, c)
    | ELet(_, _, _, _, c)
    | ESeq(_, _, c)
    | EPointer(_, _, c) => c
  }
}

///|
/// Binary operator precedences (expr parser/operator/operator.go):
/// higher binds tighter; `**`/`^` are right-associative.
pub fn binary_prec(op : String) -> Int {
  match op {
    "|" => 0
    "or" | "||" => 10
    "and" | "&&" => 15
    "=="
    | "!="
    | "<"
    | ">"
    | ">="
    | "<="
    | "in"
    | "matches"
    | "contains"
    | "startsWith"
    | "endsWith" => 20
    ".." => 25
    "+" | "-" => 30
    "*" | "/" | "%" => 60
    "**" | "^" => 100
    "??" => 500
    _ => -1
  }
}

///|
/// Whether an infix operator is right-associative.
pub fn right_assoc(op : String) -> Bool {
  op == "**" || op == "^"
}

///|
/// Rendering an AST as a compact s-expression string — the test
/// oracle for parser structure assertions.
pub fn dump(n : ENode) -> String {
  match n {
    ENil(_, _) => "nil"
    EBool(b, _, _) => if b { "true" } else { "false" }
    EInt(i, _, _) => "int:" + i.to_string()
    EFloat(d, _, _) => "float:" + d.to_string()
    EStr(s, _, _) => "str:" + s
    EBytes(_, _, _) => "bytes"
    EIdent(s, _, _) => "id:" + s
    EMember(b, name, opt, _, _) =>
      "member(" + dump(b) + "." + name + (if opt { "?)" } else { ")" })
    EIndex(b, i, _, _) => "index(" + dump(b) + "," + dump(i) + ")"
    ESlice(b, f, t, _, _) =>
      "slice(" + dump(b) + "," + opt_dump(f) + "," + opt_dump(t) + ")"
    ECall(c, args, _, _) => {
      let out = StringBuilder::new()
      out.write_string("call(" + dump(c))
      for a in args {
        out.write_string("," + dump(a))
      }
      out.write_string(")")
      out.to_string()
    }
    EPred(inner, _, _) => "pred(" + dump(inner) + ")"
    EArray(xs, _, _) => {
      let out = StringBuilder::new()
      out.write_string("arr[")
      for i in 0..<xs.length() {
        if i > 0 {
          out.write_string(",")
        }
        out.write_string(dump(xs[i]))
      }
      out.write_string("]")
      out.to_string()
    }
    EMap(pairs, _, _) => {
      let out = StringBuilder::new()
      out.write_string("map{")
      for i in 0..<pairs.length() {
        let (k, v) = pairs[i]
        if i > 0 {
          out.write_string(",")
        }
        out.write_string(dump(k) + ":" + dump(v))
      }
      out.write_string("}")
      out.to_string()
    }
    EUnary(op, x, _, _) => "un(" + op + "," + dump(x) + ")"
    EBinary(op, l, r, _, _) => "bin(" + op + "," + dump(l) + "," + dump(r) + ")"
    ECond(t, c, a, _, _) =>
      "cond(" + dump(t) + "," + opt_dump(c) + "," + opt_dump(a) + ")"
    ELet(name, v, rest, _, _) =>
      "let(" + name + "," + dump(v) + "," + dump(rest) + ")"
    ESeq(xs, _, _) => {
      let out = StringBuilder::new()
      out.write_string("seq[")
      for i in 0..<xs.length() {
        if i > 0 {
          out.write_string(";")
        }
        out.write_string(dump(xs[i]))
      }
      out.write_string("]")
      out.to_string()
    }
    EPointer(kind, _, _) => "ptr:" + kind
  }
}

///|
fn opt_dump(o : ENode?) -> String {
  match o {
    Some(x) => dump(x)
    None => "?"
  }
}
