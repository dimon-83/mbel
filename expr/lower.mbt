// SPDX-License-Identifier: Apache-2.0
// mbel expr package — lowering the expr AST to the legacy AstNode so
// the existing dual-engine evaluator (tree-walk + bytecode VM) can
// execute expr-dialect programs. Bridge stage: method calls gain
// dedicated evaluation later.

///|
pub(all) suberror LowerError {
  LowerErr(String)
}

///|
/// Lowers a parsed expr AST to the legacy AST the engines execute.
pub fn lower(n : ENode) -> @ast.AstNode raise LowerError {
  match n {
    ENil(_, _) => @ast.literal(@ast.NullVal)
    EBool(b, _, _) => @ast.literal(@ast.BoolVal(b))
    EInt(i, _, _) => @ast.literal(@ast.IntVal(i))
    EFloat(d, _, _) => @ast.literal(@ast.NumVal(d))
    EStr(s, _, _) => @ast.literal(@ast.StrVal(s))
    // Byte literals evaluate to BytesVal (stage 4.4.3 tail); the
    // legacy dialect has no byte literals, so this only ever runs on
    // the expr front end.
    EBytes(b, _, _) => @ast.literal(@ast.BytesVal(b))
    EIdent(name, _, _) => @ast.identifier(name)
    EMember(base, name, _, _, _) => {
      // ?. lowers to plain member access: mbel's drill-down already
      // returns nil/undefined for nil bases (nil-safe by default).
      let b = lower(base)
      let member = @ast.identifier(name)
      member.from = Some(b)
      member
    }
    EIndex(base, idx, _, _) => {
      let b = lower(base)
      match idx {
        // Bracket predicate `items[.expr]` (Jexl-compat extension):
        // lower as a relative filter, evaluated per element. Plain
        // indexing keeps the static-filter form.
        EPred(inner, _, _) => @ast.filter_expression(lower(inner), true, b)
        other => @ast.filter_expression(lower(other), false, b)
      }
    }
    ESlice(base, from, to, _, _) => {
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
    ECall(callee, args, _, _) => lower_call(callee, args)
    EPred(inner, _, _) => lower(inner)
    EArray(items, _, _) => {
      let arr = @ast.array_literal()
      for x in items {
        arr.array_value.push(lower(x))
      }
      arr
    }
    EMap(pairs, _, _) => {
      let obj = @ast.object_literal()
      for kv in pairs {
        let (k, v) = kv
        let key_node = lower_key(k)
        obj.obj_value.push((key_node, lower(v)))
      }
      obj
    }
    EUnary(op, x, _, _) => {
      let inner = lower(x)
      match op {
        "-" =>
          match x {
            EInt(i, _, _) => return @ast.literal(@ast.IntVal(-i))
            EFloat(d, _, _) => return @ast.literal(@ast.NumVal(-d))
            _ => ()
          }
        _ => ()
      }
      let u = @ast.unary_expr(op)
      u.right = Some(inner)
      u
    }
    EBinary(op, l, r, _, _) => {
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
    ECond(t, c, a, _, _) => {
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
    ELet(name, v, rest, _, _) => {
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
    ESeq(items, _, _) => {
      let s = @ast.sequence()
      for item in items {
        for x in seq_items(item) {
          s.args.push(x)
        }
      }
      s
    }
    EPointer(kind, _, _) => {
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
    ELet(name, v, rest, _, _) => {
      let out : Array[@ast.AstNode] = [@ast.variable_declarator(name, lower(v))]
      for x in seq_items(rest) {
        out.push(x)
      }
      out
    }
    ESeq(items, _, _) => {
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
    EIdent(f, _, _) => f
    EMember(_, m, _, _, _) =>
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
    EIdent(name, _, _) => name
    EStr(s, _, _) => s
    EInt(i, _, _) => i.to_double().to_string()
    EFloat(d, _, _) => d.to_string()
    _ => raise LowerError::LowerErr("invalid map key")
  }
}
