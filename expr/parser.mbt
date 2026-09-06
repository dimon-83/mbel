// SPDX-License-Identifier: Apache-2.0
// mbel expr package — recursive-descent + Pratt parser for the
// expr-lang dialect.
//
// Covers: the full literal family, identifiers, member access with
// optional chaining (?. and ?.[), indexing and slicing, calls, map /
// array literals, unary (! - + not), the full infix table (incl.
// right-assoc **/^, range .., coalescing ??), chained comparisons
// (a < b < c -> conjunction), not-prefixed suffix ops (not in etc.),
// ternary and if/else, let + `;` sequences, brace-wrapped predicates
// `{expr}` (disambiguated from map literals), predicate pointers, and
// `$env`.

///|
pub(all) suberror ParseErrorExpr {
  ParseErrExpr(String, Int, Int) // message, line, col
}

///|
struct Parser {
  toks : Array[Token]
  mut pos : Int
  mut in_predicate : Bool
}

///|
/// Parses an expr-language source string into the expr AST.
pub fn parse(source : String) -> ENode raise ParseErrorExpr {
  let toks = tokenize(source) catch {
    LexErr(msg, line, col) => raise ParseErrorExpr::ParseErrExpr(msg, line, col)
  }
  let p : Parser = { toks, pos: 0, in_predicate: false }
  let e = p.parse_program()
  p.expect_eof()
  e
}

///|
fn Parser::cur(self : Parser) -> Token {
  self.toks[self.pos]
}

///|
fn Parser::peek(self : Parser) -> Token {
  let next = self.pos + 1
  if next < self.toks.length() {
    self.toks[next]
  } else {
    self.toks[self.toks.length() - 1]
  }
}

///|
/// Always raises — typed as returning ENode so call sites in value
/// position typecheck.
fn Parser::err(self : Parser, msg : String) -> ENode raise ParseErrorExpr {
  let t = self.cur()
  raise ParseErrorExpr::ParseErrExpr(msg, t.line, t.col)
}

///|
fn Parser::expect_eof(self : Parser) -> Unit raise ParseErrorExpr {
  if self.cur().kind
    is (TkIdent
    | TkKeyword
    | TkInt
    | TkFloat
    | TkStr
    | TkBytes
    | TkOperator
    | TkPointer) {
    let _ = self.err("unexpected trailing input")
  }
}

///|
fn Parser::at_op(self : Parser, op : String) -> Bool {
  let t = self.cur()
  t.kind is TkOperator && t.text == op
}

///|
fn Parser::at_kw(self : Parser, kw : String) -> Bool {
  let t = self.cur()
  t.kind is TkKeyword && t.text == kw
}

///|
fn Parser::eat_op(self : Parser, op : String) -> Bool {
  if self.at_op(op) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::eat_kw(self : Parser, kw : String) -> Bool {
  if self.at_kw(kw) {
    self.pos += 1
    true
  } else {
    false
  }
}

///|
fn Parser::expect_op(self : Parser, op : String) -> Unit raise ParseErrorExpr {
  if !self.eat_op(op) {
    let t = self.cur()
    raise ParseErrorExpr::ParseErrExpr("expected '" + op + "'", t.line, t.col)
  }
}

///|
// program := let-chain | expr (';' expr)*
fn Parser::parse_program(self : Parser) -> ENode raise ParseErrorExpr {
  if self.at_kw("let") {
    return self.parse_let()
  }
  let first = self.parse_expr()
  if self.eat_op(";") {
    let items : Array[ENode] = [first]
    while !(self.cur().kind is TkEOF) {
      if self.at_kw("let") {
        items.push(self.parse_let())
      } else {
        items.push(self.parse_expr())
      }
      if !self.eat_op(";") {
        break
      }
    }
    return ESeq(items)
  }
  first
}

///|
// let x = e; let y = e; rest — declarations chained via ELet.
fn Parser::parse_let(self : Parser) -> ENode raise ParseErrorExpr {
  self.pos += 1 // consume `let`
  if self.cur().kind is TkIdent {
    let name = self.cur().text
    self.pos += 1
    self.expect_op("=")
    let value = self.parse_expr()
    self.expect_op(";")
    let rest = self.parse_program_rest()
    return ELet(name, value, rest)
  }
  self.err("expected identifier after 'let'")
}

///|
// rest of a program after a `let` declaration.
fn Parser::parse_program_rest(self : Parser) -> ENode raise ParseErrorExpr {
  if self.at_kw("let") {
    return self.parse_let()
  }
  let first = self.parse_expr()
  if self.eat_op(";") {
    let items : Array[ENode] = [first]
    while !(self.cur().kind is TkEOF) {
      if self.at_kw("let") {
        items.push(self.parse_let())
      } else {
        items.push(self.parse_expr())
      }
      if !self.eat_op(";") {
        break
      }
    }
    return ESeq(items)
  }
  first
}

///|
/// Pratt expression parsing: starts at the lowest precedence (pipe),
/// if/else and ternary handled above/below the binary loop.
fn Parser::parse_expr(self : Parser) -> ENode raise ParseErrorExpr {
  let e = self.parse_binary(0)
  self.parse_ternary(e)
}

///|
fn Parser::parse_ternary(
  self : Parser,
  cond_e : ENode,
) -> ENode raise ParseErrorExpr {
  if !self.at_op("?") {
    return cond_e
  }
  self.pos += 1
  if self.at_op(":") {
    // elvis: a ?: b
    self.pos += 1
    let alt = self.parse_expr()
    return ECond(cond_e, None, Some(alt))
  }
  let consequent = self.parse_expr()
  self.expect_op(":")
  let alt = self.parse_expr()
  ECond(cond_e, Some(consequent), Some(alt))
}

///|
fn op_of(t : Token) -> String? {
  match t.kind {
    TkOperator =>
      match t.text {
        "|"
        | "||"
        | "&&"
        | "=="
        | "!="
        | "<"
        | ">"
        | ">="
        | "<="
        | "+"
        | "-"
        | "*"
        | "/"
        | "%"
        | "^"
        | "??"
        | ".."
        | "**" => Some(t.text)
        _ => None
      }
    TkKeyword =>
      match t.text {
        "and"
        | "or"
        | "in"
        | "matches"
        | "contains"
        | "startsWith"
        | "endsWith" => Some(t.text)
        _ => None
      }
    _ => None
  }
}

///|
fn Parser::parse_binary(
  self : Parser,
  min_prec : Int,
) -> ENode raise ParseErrorExpr {
  let mut left = self.parse_unary()
  while true {
    // not-prefixed suffix operators: `not in`, `not matches`, …
    if self.at_kw("not") {
      match self.peek().kind {
        TkKeyword =>
          match self.peek().text {
            "in" | "matches" | "contains" | "startsWith" | "endsWith" => {
              self.pos += 1 // consume `not`
              let op = self.cur().text
              self.pos += 1
              let prec = binary_prec(op)
              if prec < min_prec {
                self.pos -= 2
                break
              }
              let right = self.parse_binary(prec + 1)
              left = EUnary("not", EBinary(op, left, right))
              continue
            }
            _ => ()
          }
        _ => ()
      }
    }
    let op = match op_of(self.cur()) {
      Some(o) => o
      None => break
    }
    let prec = binary_prec(op)
    if prec < min_prec {
      break
    }
    self.pos += 1
    if op == "|" {
      // pipe: right side must be a call whose first arg becomes left
      let right = self.parse_binary(prec + 1)
      left = rewrite_pipe(left, right)
      continue
    }
    let right = if right_assoc(op) {
      self.parse_binary(prec)
    } else {
      self.parse_binary(prec + 1)
    }
    left = EBinary(op, left, right)
    // chained comparisons: a < b < c  ->  (a<b) && (b<c)
    if is_comparison(op) {
      while true {
        let op2 = match op_of(self.cur()) {
          Some(o) => o
          None => break
        }
        if !is_comparison(op2) {
          break
        }
        self.pos += 1
        let mid = left_midpoint(left)
        let right2 = self.parse_binary(binary_prec(op2) + 1)
        left = EBinary("and", left, EBinary(op2, mid, right2))
      }
    }
  }
  left
}

///|
fn is_comparison(op : String) -> Bool {
  op == "<" || op == ">" || op == "<=" || op == ">="
}

///|
/// The midpoint of a chained comparison: for `a < b`, `b`.
fn left_midpoint(left : ENode) -> ENode {
  match left {
    EBinary(_, _, r) => r
    other => other
  }
}

///|
/// `x | f(a, …)` desugars to `f(x, a, …)`; `x | f` to `f(x)`.
fn rewrite_pipe(left : ENode, right : ENode) -> ENode {
  match right {
    ECall(callee, args) => {
      let all : Array[ENode] = [left]
      for a in args {
        all.push(a)
      }
      ECall(callee, all)
    }
    EIdent(f) => ECall(EIdent(f), [left])
    other => ECall(other, [left])
  }
}

///|
fn Parser::parse_unary(self : Parser) -> ENode raise ParseErrorExpr {
  if self.at_op("!") {
    self.pos += 1
    return EUnary("!", self.parse_unary())
  }
  if self.at_op("-") {
    self.pos += 1
    return EUnary("-", self.parse_unary())
  }
  if self.at_op("+") {
    self.pos += 1
    return self.parse_unary()
  }
  if self.at_kw("not") {
    // not is a unary operator only when not followed by an infix
    // keyword (not in / not matches …) — those are handled in the
    // binary loop after a left operand exists.
    match self.peek().kind {
      TkKeyword | TkEOF => ()
      TkIdent | TkInt | TkFloat | TkStr | TkBytes | TkPointer | TkOperator => {
        let t = self.peek()
        if t.kind is TkOperator &&
          !(t.text == "(" ||
          t.text == "[" ||
          t.text == "{" ||
          t.text == "." ||
          t.text == "?.") {
          // e.g. `not )` — treat as identifier below
        } else {
          self.pos += 1
          return EUnary("not", self.parse_unary())
        }
      }
    }
  }
  self.parse_postfix()
}

///|
fn Parser::parse_postfix(self : Parser) -> ENode raise ParseErrorExpr {
  let mut e = self.parse_primary()
  while true {
    if self.at_op(".") {
      self.pos += 1
      if self.cur().kind is TkIdent {
        let name = self.cur().text
        self.pos += 1
        // method call or plain member
        if self.at_op("(") {
          let args = self.parse_call_args()
          e = ECall(EMember(e, name, false), args)
        } else {
          e = EMember(e, name, false)
        }
      } else {
        let _ = self.err("expected identifier after '.'")
      }
      continue
    }
    if self.at_op("?.") {
      self.pos += 1
      if self.at_op("[") {
        self.pos += 1
        let idx = self.parse_expr()
        self.expect_op("]")
        e = EIndex(e, idx) // nil-safe by evaluation semantics
        continue
      }
      if self.cur().kind is TkIdent {
        let name = self.cur().text
        self.pos += 1
        e = EMember(e, name, true)
      } else {
        let _ = self.err("expected identifier after '?.")
      }
      continue
    }
    if self.at_op("[") {
      self.pos += 1
      if self.at_op(":") {
        // [:to] or [:]
        self.pos += 1
        let to : ENode? = if self.at_op("]") {
          None
        } else {
          Some(self.parse_expr())
        }
        self.expect_op("]")
        e = ESlice(e, None, to)
        continue
      }
      let idx = self.parse_expr()
      if self.at_op(":") {
        self.pos += 1
        let to : ENode? = if self.at_op("]") {
          None
        } else {
          Some(self.parse_expr())
        }
        self.expect_op("]")
        e = ESlice(e, Some(idx), to)
        continue
      }
      self.expect_op("]")
      e = EIndex(e, idx)
      continue
    }
    if self.at_op("(") {
      let args = self.parse_call_args_for(e)
      e = ECall(e, args)
      continue
    }
    break
  }
  e
}

///|
/// Parses `(args)`. Inside argument position, `{` starts either a map
/// literal or a brace-wrapped predicate — disambiguated like expr:
/// map keys must start with an identifier/string/number/paren.
fn Parser::parse_call_args(self : Parser) -> Array[ENode] raise ParseErrorExpr {
  self.parse_call_args_for(ENil)
}

///|
/// Parses `(args)`; when the callee is an aggregate function, the
/// second argument parses in predicate context (bare `.field` access
/// allowed), mirroring expr's predicate-position rule.
fn Parser::parse_call_args_for(
  self : Parser,
  callee : ENode,
) -> Array[ENode] raise ParseErrorExpr {
  self.expect_op("(")
  let args : Array[ENode] = []
  if self.eat_op(")") {
    return args
  }
  let callee_name = match callee {
    EIdent(f) => f
    _ => ""
  }
  let mut arg_idx = 0
  while true {
    let saved = self.in_predicate
    if arg_idx == 1 && @grammar.is_aggregate(callee_name) {
      self.in_predicate = true
    }
    if self.at_op("{") && self.brace_starts_map() {
      args.push(self.parse_map_literal())
    } else if self.at_op("{") {
      self.pos += 1
      let inner = self.parse_expr()
      self.expect_op("}")
      args.push(EPred(inner))
    } else {
      args.push(self.parse_expr())
    }
    self.in_predicate = saved
    arg_idx += 1
    if self.eat_op(",") {
      continue
    }
    break
  }
  self.expect_op(")")
  args
}

///|
/// Decides whether a `{` at the current position opens a map literal
/// (keys are identifiers/strings/numbers/paren-exprs followed by `:`
/// or an immediate `}`).
fn Parser::brace_starts_map(self : Parser) -> Bool {
  let t = self.peek()
  match t.kind {
    TkEOF => true
    TkIdent =>
      false == self.is_kw_text(t) && self.next_is_colon_or_comma_like(1)
    TkStr(_) => self.next_is_colon_or_comma_like(1)
    TkInt(_) | TkFloat(_) => self.next_is_colon_or_comma_like(1)
    TkOperator =>
      if t.text == "}" {
        true
      } else {
        t.text == "(" && self.paren_is_key(1)
      }
    _ => false
  }
}

///|
fn Parser::is_kw_text(self : Parser, t : Token) -> Bool {
  t.kind is TkKeyword
}

///|
fn Parser::next_is_colon_or_comma_like(self : Parser, offset : Int) -> Bool {
  let idx = self.pos + 1 + offset
  if idx >= self.toks.length() {
    return false
  }
  let t = self.toks[idx]
  t.kind is TkOperator && (t.text == ":" || t.text == "," || t.text == "}")
}

///|
/// After `{` + `(`, decides if the parenthesized expression is a map
/// key: scans to the matching `)` and checks for `:`.
fn Parser::paren_is_key(self : Parser, offset : Int) -> Bool {
  let mut depth = 0
  let mut idx = self.pos + 1 + offset
  while idx < self.toks.length() {
    let t = self.toks[idx]
    if t.kind is TkOperator {
      if t.text == "(" {
        depth += 1
      } else if t.text == ")" {
        if depth == 0 {
          idx += 1
          break
        }
        depth -= 1
      }
    }
    idx += 1
  }
  if idx < self.toks.length() {
    let t = self.toks[idx]
    t.kind is TkOperator && (t.text == ":" || t.text == ",")
  } else {
    false
  }
}

///|
fn Parser::parse_map_literal(self : Parser) -> ENode raise ParseErrorExpr {
  self.expect_op("{")
  let pairs : Array[(ENode, ENode)] = []
  if self.eat_op("}") {
    return EMap(pairs)
  }
  while true {
    let key : ENode = match self.cur().kind {
      TkIdent => EIdent(self.cur().text)
      TkStr => EStr(self.cur().text)
      TkInt => int_from_text(self.cur().text)
      TkFloat => float_from_text(self.cur().text)
      TkOperator =>
        if self.at_op("(") {
          self.pos += 1
          let e = self.parse_expr()
          self.expect_op(")")
          e
        } else {
          self.err("invalid map key")
        }
      _ => self.err("invalid map key")
    }
    self.pos += 1
    self.expect_op(":")
    let value = self.parse_expr()
    pairs.push((key, value))
    if self.eat_op(",") {
      if self.at_op("}") {
        self.pos += 1
        break
      }
      continue
    }
    self.expect_op("}")
    break
  }
  EMap(pairs)
}

///|
fn Parser::parse_primary(self : Parser) -> ENode raise ParseErrorExpr {
  let t = self.cur()
  match t.kind {
    TkInt => {
      let text = t.text
      self.pos += 1
      int_from_text(text)
    }
    TkFloat => {
      let text = t.text
      self.pos += 1
      float_from_text(text)
    }
    TkStr => {
      let sv = t.text
      self.pos += 1
      EStr(sv)
    }
    TkBytes => {
      let bv = t.text
      self.pos += 1
      EBytes(bytes_from_str(bv))
    }
    TkPointer => {
      let text = t.text
      // expr supports exactly the pointers `#`, `#index`, `#acc`; any
      // other suffix (`#age` etc.) is a compile error in expr.
      if text != "#" && text != "#index" && text != "#acc" {
        let e = self.err("unknown pointer '" + text + "'")
        e
      } else {
        self.pos += 1
        EPointer(text)
      }
    }
    TkKeyword =>
      match t.text {
        "true" => {
          self.pos += 1
          EBool(true)
        }
        "false" => {
          self.pos += 1
          EBool(false)
        }
        "nil" => {
          self.pos += 1
          ENil
        }
        "if" => self.parse_if()
        other_kw => {
          let _ = self.err("unexpected keyword '" + other_kw + "'")
          ENil
        }
      }
    TkIdent => {
      let name = t.text
      self.pos += 1
      // predicate-relative member: `.name` sugar handled via in_predicate
      // flag at the dot site; bare identifiers are plain.
      if self.in_predicate && self.at_op(".") {
        // `.field` inside a predicate = pointer member access
        self.pos += 1
        if self.cur().kind is TkIdent {
          let f = self.cur().text
          self.pos += 1
          return EMember(EPointer("#"), f, false)
        }
        let _ = self.err("expected identifier after '.' in predicate")
      }
      EIdent(name)
    }
    TkOperator =>
      if self.at_op("(") {
        self.pos += 1
        let e = self.parse_expr()
        self.expect_op(")")
        e
      } else if self.at_op("[") {
        self.parse_array_literal()
      } else if self.at_op("{") {
        self.parse_map_literal()
      } else if self.at_op(".") && self.in_predicate {
        // predicate-relative field access: `.name` == `#.name`
        self.pos += 1
        if self.cur().kind is TkIdent {
          let f = self.cur().text
          self.pos += 1
          EMember(EPointer("#"), f, false)
        } else {
          let _ = self.err("expected identifier after '.' in predicate")
          ENil
        }
      } else {
        let _ = self.err("unexpected token '" + t.text + "'")
        ENil
      }
    TkEOF => self.err("unexpected end of expression")
  }
}

///|
fn Parser::parse_array_literal(self : Parser) -> ENode raise ParseErrorExpr {
  self.expect_op("[")
  let items : Array[ENode] = []
  if self.eat_op("]") {
    return EArray(items)
  }
  while true {
    items.push(self.parse_expr())
    if self.eat_op(",") {
      if self.at_op("]") {
        self.pos += 1
        break
      }
      continue
    }
    self.expect_op("]")
    break
  }
  EArray(items)
}

///|
/// if cond { a } else { b } — else-if chains nest naturally.
fn Parser::parse_if(self : Parser) -> ENode raise ParseErrorExpr {
  self.pos += 1 // consume `if`
  let cond = self.parse_expr()
  self.expect_op("{")
  let then = self.parse_expr()
  self.expect_op("}")
  if self.eat_kw("else") {
    if self.at_kw("if") {
      let nested = self.parse_if()
      return ECond(cond, Some(then), Some(nested))
    }
    self.expect_op("{")
    let alt = self.parse_expr()
    self.expect_op("}")
    return ECond(cond, Some(then), Some(alt))
  }
  ECond(cond, Some(then), None)
}

///|

///|
/// Byte-string content chars (each a single byte value) to Bytes.
fn bytes_from_str(s : String) -> Bytes {
  let buf : Array[Byte] = []
  for c in s {
    buf.push((c.to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(buf)
}

///|
fn int_from_text(text : String) -> ENode {
  // Radix-prefixed forms arrive as "int:<digits>" (already folded);
  // plain decimals arrive as raw digits.
  let chars = text.to_array()
  if chars.length() > 4 && chars[0] == 'i' && chars[1] == 'n' {
    EInt(parse_radix(text[4:].to_owned(), 10))
  } else {
    EInt(parse_radix(text, 10))
  }
}

///|
fn float_from_text(text : String) -> ENode {
  let chars = text.to_array()
  if chars.length() > 6 && chars[0] == 'f' && chars[1] == 'l' {
    EFloat(parse_float_str(text[6:].to_owned()))
  } else {
    EFloat(parse_float_str(text))
  }
}
