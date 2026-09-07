// SPDX-License-Identifier: Apache-2.0
// mbel expr package — lowering the expr AST to the legacy AstNode so
// the existing dual-engine evaluator (tree-walk + bytecode VM) can
// execute expr-dialect programs. Bridge stage: slices, byte values,
// method calls, and let/sequences gain dedicated evaluation later.

///|
pub(all) suberror LowerError {
  LowerErr(String)
}

///|
/// Lowers a parsed expr AST to the legacy AST the engines execute.
pub fn lower(n : ENode) -> @ast.AstNode raise LowerError {
  match n {
    ENil => @ast.literal(@ast.NullVal)
    EBool(b) => @ast.literal(@ast.BoolVal(b))
    EInt(i) => @ast.literal(@ast.IntVal(i))
    EFloat(d) => @ast.literal(@ast.NumVal(d))
    EStr(s) => @ast.literal(@ast.StrVal(s))
    EBytes(_) =>
      raise LowerError::LowerErr(
        "byte-string values need the typed value model (stage 4.4.3)",
      )
    EIdent(name) => @ast.identifier(name)
    EMember(base, name, _) => {
      // ?. lowers to plain member access: mbel's drill-down already
      // returns nil/undefined for nil bases (nil-safe by default).
      let b = lower(base)
      let member = @ast.identifier(name)
      member.from = Some(b)
      member
    }
    EIndex(base, idx) => {
      let b = lower(base)
      match idx {
        // Bracket predicate `items[.expr]` (Jexl-compat extension):
        // lower as a relative filter, evaluated per element. Plain
        // indexing keeps the static-filter form.
        EPred(inner) => @ast.filter_expression(lower(inner), true, b)
        other => @ast.filter_expression(lower(other), false, b)
      }
    }
    ESlice(base, from, to) => {
      let b = lower(base)
      let f = match from {
        Some(x) => Some(lower(x))
        None => None
      }
      let t = match to {
        Some(x) => Some(lower(x))
        None => None
      }
      @ast.slice_node(b, f, t)
    }
    ECall(callee, args) => lower_call(callee, args)
    EPred(inner) => lower(inner)
    EArray(items) => {
      let arr = @ast.array_literal()
      for x in items {
        arr.array_value.push(lower(x))
      }
      arr
    }
    EMap(pairs) => {
      let obj = @ast.object_literal()
      for kv in pairs {
        let (k, v) = kv
        let key_node = lower_key(k)
        obj.obj_value.push((key_node, lower(v)))
      }
      obj
    }
    EUnary(op, x) => {
      let inner = lower(x)
      match op {
        "-" =>
          match x {
            EInt(i) => return @ast.literal(@ast.IntVal(-i))
            EFloat(d) => return @ast.literal(@ast.NumVal(-d))
            _ => ()
          }
        _ => ()
      }
      let u = @ast.unary_expr(op)
      u.right = Some(inner)
      u
    }
    EBinary(op, l, r) => {
      let lo = lower(l)
      let ro = lower(r)
      let mopped = match op {
        // expr's ** is mbel's ^ (same power semantics); the parser
        // already encoded right-associativity in the tree shape.
        "**" => "^"
        "and" => "&&"
        "or" => "||"
        other => other
      }
      let b = @ast.binary_expr(mopped, lo)
      b.right = Some(ro)
      b
    }
    ECond(t, c, a) => {
      let cond = @ast.conditional()
      cond.cond_test = Some(lower(t))
      match c {
        Some(x) => cond.consequent = Some(lower(x))
        None => ()
      }
      match a {
        Some(x) => cond.alternate = Some(lower(x))
        None => raise LowerError::LowerErr("conditional without alternate")
      }
      cond
    }
    ELet(name, v, rest) => {
      let items : Array[@ast.AstNode] = [
        @ast.variable_declarator(name, lower(v)),
      ]
      for x in seq_items(rest) {
        items.push(x)
      }
      let s = @ast.sequence()
      s.args = items
      s
    }
    ESeq(items) => {
      let s = @ast.sequence()
      for item in items {
        for x in seq_items(item) {
          s.args.push(x)
        }
      }
      s
    }
    EPointer(kind) => {
      let p = @ast.pointer(kind)
      p
    }
  }
}

///|
/// Flattens a let-chain/sequence tail into sequence items, expanding
/// nested ELet/ESeq (parse_let consumes its whole rest, so a `let`
/// inside a sequence arrives with its body already attached).
fn seq_items(n : ENode) -> Array[@ast.AstNode] raise LowerError {
  match n {
    ELet(name, v, rest) => {
      let out : Array[@ast.AstNode] = [@ast.variable_declarator(name, lower(v))]
      for x in seq_items(rest) {
        out.push(x)
      }
      out
    }
    ESeq(items) => {
      let out : Array[@ast.AstNode] = []
      for item in items {
        for x in seq_items(item) {
          out.push(x)
        }
      }
      out
    }
    other => [lower(other)]
  }
}

///|
fn lower_call(
  callee : ENode,
  args : Array[ENode],
) -> @ast.AstNode raise LowerError {
  let fname = match callee {
    EIdent(f) => f
    EMember(_, m, _) =>
      raise LowerError::LowerErr(
        "method call '" +
        m +
        "' is not supported on data values (expr cut: Go-reflection methods)",
      )
    _ => raise LowerError::LowerErr("invalid call target")
  }
  let fc = @ast.function_call(fname, "functions")
  for i in 0..<args.length() {
    let a = args[i]
    let lowered = lower(a)
    // expr predicate position: second argument of an aggregate call,
    // brace-wrapped or bare — flagged so the evaluator keeps it as AST.
    if i == 1 && @grammar.is_aggregate(fname) {
      lowered.is_pred = true
    }
    fc.args.push(lowered)
  }
  fc
}

///|
fn lower_key(k : ENode) -> String raise LowerError {
  match k {
    EIdent(name) => name
    EStr(s) => s
    EInt(i) => i.to_double().to_string()
    EFloat(d) => d.to_string()
    _ => raise LowerError::LowerErr("invalid map key")
  }
}
