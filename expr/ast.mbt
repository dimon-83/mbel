// SPDX-License-Identifier: Apache-2.0
// mbel expr package — AST node set for the expr-lang dialect.
//
// Frozen per the stage-4.4 review: this node set is the contract the
// checker and the VM instruction encoding will attach to; lowering to
// the legacy AstNode is a bridge until dedicated evaluation lands.

///|
/// The expr dialect AST. Positions live on tokens; nodes are plain
/// values so tests assert structure directly.
pub(all) enum ENode {
  ENil
  EBool(Bool)
  EInt(Int64) // decimal/hex/octal/binary, `_` separators folded out
  EFloat(Double)
  EStr(String)
  EBytes(Bytes)
  EIdent(String) // identifiers and $env
  EMember(ENode, String, Bool) // base.name (opt=true for ?.name)
  EIndex(ENode, ENode) // base[index]
  ESlice(ENode, ENode?, ENode?) // base[from:to], either bound optional
  ECall(ENode, Array[ENode]) // callee(args...)
  EPred(ENode) // brace-wrapped or predicate-position expression
  EArray(Array[ENode])
  EMap(Array[(ENode, ENode)])
  EUnary(String, ENode) // ! - + not
  EBinary(String, ENode, ENode) // all infix ops incl. `..` and `**`
  ECond(ENode, ENode?, ENode?) // ternary ?: and if/else (consequent
  // may be None for the `a ?: b` form)
  ELet(String, ENode, ENode) // let x = value; rest
  ESeq(Array[ENode]) // a; b; c
  EPointer(String) // # / #index / #acc
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
    ENil => "nil"
    EBool(b) => if b { "true" } else { "false" }
    EInt(i) => "int:" + i.to_string()
    EFloat(d) => "float:" + d.to_string()
    EStr(s) => "str:" + s
    EBytes(_) => "bytes"
    EIdent(s) => "id:" + s
    EMember(b, name, opt) =>
      "member(" + dump(b) + "." + name + (if opt { "?)" } else { ")" })
    EIndex(b, i) => "index(" + dump(b) + "," + dump(i) + ")"
    ESlice(b, f, t) =>
      "slice(" + dump(b) + "," + opt_dump(f) + "," + opt_dump(t) + ")"
    ECall(c, args) => {
      let out = StringBuilder::new()
      out.write_string("call(" + dump(c))
      for a in args {
        out.write_string("," + dump(a))
      }
      out.write_string(")")
      out.to_string()
    }
    EPred(inner) => "pred(" + dump(inner) + ")"
    EArray(xs) => {
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
    EMap(pairs) => {
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
    EUnary(op, x) => "un(" + op + "," + dump(x) + ")"
    EBinary(op, l, r) => "bin(" + op + "," + dump(l) + "," + dump(r) + ")"
    ECond(t, c, a) =>
      "cond(" + dump(t) + "," + opt_dump(c) + "," + opt_dump(a) + ")"
    ELet(name, v, rest) =>
      "let(" + name + "," + dump(v) + "," + dump(rest) + ")"
    ESeq(xs) => {
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
    EPointer(kind) => "ptr:" + kind
  }
}

///|
fn opt_dump(o : ENode?) -> String {
  match o {
    Some(x) => dump(x)
    None => "?"
  }
}
