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
/// Default token budget for expr-source parsing, mirroring the legacy
/// parser's node budget (expr's MaxNodes). 0 disables the limit.
pub fn default_max_tokens() -> Int {
  10000
}

///|
/// Default parser recursion guard. The expr parser recurses per
/// nesting construct (parens, unary chains, right-assoc operators,
/// else-if chains); MoonBit's wasm-gc target has a fixed stack and
/// host JS engines have byte-sized stack limits, so recursion is
/// capped conservatively (each nesting level costs several parser
/// frames; 1000 frames ≈ 250 construct levels). Mirrors the legacy
/// parser's nesting budget spirit.
pub fn default_max_parse_frames() -> Int {
  1000
}

///|
struct Parser {
  toks : Array[Token]
  mut pos : Int
  mut in_predicate : Bool
  // Whether the expression being parsed began at precedence 0 (a
  // top-level/program site): expr only accepts `if`/`let` at those
  // sites, never as a binary operand (`1 + if …` is a parse error).
  mut at_expr0 : Bool
  // budget: recursion-frame guard
  max_frames : Int
  mut frames : Int
}

///|
/// Parses an expr-language source string into the expr AST (no token
/// budget; the recursion guard still applies).
pub fn parse(source : String) -> ENode raise ParseErrorExpr {
  parse_limited(source, 0)
}

///|
/// Parses with a token budget (0 disables): expressions consuming
/// more than `max_tokens` tokens are rejected, mirroring the legacy
/// parser's node budget and expr's MaxNodes option. The recursion
/// guard always applies.
pub fn parse_limited(
  source : String,
  max_tokens : Int,
) -> ENode raise ParseErrorExpr {
  let toks = tokenize(source) catch {
    LexErr(msg, line, col) => raise ParseErrorExpr::ParseErrExpr(msg, line, col)
  }
  let p : Parser = {
    toks,
    pos: 0,
    in_predicate: false,
    at_expr0: false,
    max_frames: default_max_parse_frames(),
    frames: 0,
  }
  let e = p.parse_program()
  p.expect_eof()
  ast_budget_check(e, max_tokens)
  e
}

///|
/// Maximum AST depth an expr source may produce. Parsing itself is
/// recursion-guarded (see default_max_parse_frames); this bound keeps
/// later phases that recurse over the AST (lowering, constant
/// folding, the walk engine's eval recursion) within the host stack,
/// mirroring the legacy parser's nesting budget.
pub fn default_max_ast_depth() -> Int {
  1000
}

///|
/// Iterative budget check over a parsed AST: counts nodes (0 =
/// unlimited) and tracks the maximum tree depth without host
/// recursion, so deep-but-legally-parsed shapes are rejected here
/// rather than overflowing the stack in lowering/folding.
fn ast_budget_check(n : ENode, max_nodes : Int) -> Unit raise ParseErrorExpr {
  let stack : Array[(ENode, Int)] = [(n, 1)]
  let mut count = 0
  while stack.length() > 0 {
    let (node, depth) = stack.pop().unwrap()
    count += 1
    if max_nodes > 0 && count > max_nodes {
      raise ParseErrorExpr::ParseErrExpr(
        "expression is too large (more than " +
        max_nodes.to_string() +
        " nodes)",
        1,
        1,
      )
    }
    if depth > default_max_ast_depth() {
      raise ParseErrorExpr::ParseErrExpr(
        "expression is too deeply nested", 1, 1,
      )
    }
    for child in node_children(node) {
      stack.push((child, depth + 1))
    }
  }
}

///|
fn node_children(n : ENode) -> Array[ENode] {
  let out : Array[ENode] = []
  match n {
    EMember(b, _, _, _, _) => out.push(b)
    EIndex(b, i, _, _) => {
      out.push(b)
      out.push(i)
    }
    ESlice(b, f, t, _, _) => {
      out.push(b)
      match f {
        Some(x) => out.push(x)
        None => ()
      }
      match t {
        Some(x) => out.push(x)
        None => ()
      }
    }
    ECall(c, args, _, _) => {
      out.push(c)
      for a in args {
        out.push(a)
      }
    }
    EPred(inner, _, _) => out.push(inner)
    EArray(xs, _, _) =>
      for x in xs {
        out.push(x)
      }
    EMap(pairs, _, _) =>
      for kv in pairs {
        let (k, v) = kv
        out.push(k)
        out.push(v)
      }
    EUnary(_, x, _, _) => out.push(x)
    EBinary(_, l, r, _, _) => {
      out.push(l)
      out.push(r)
    }
    ECond(t, c, a, _, _) => {
      out.push(t)
      match c {
        Some(x) => out.push(x)
        None => ()
      }
      match a {
        Some(x) => out.push(x)
        None => ()
      }
    }
    ELet(_, v, rest, _, _) => {
      out.push(v)
      out.push(rest)
    }
    ESeq(items, _, _) =>
      for x in items {
        out.push(x)
      }
    _ => ()
  }
  out
}

///|
/// Enter a recursion frame: every parse cycle passes through one of
/// the wrapped functions per nesting level, so the frame count bounds
/// concurrent recursion (wasm stack safety). A raise aborts the whole
/// parse, so no restore is needed on the error path.
fn Parser::enter(self : Parser) -> Unit raise ParseErrorExpr {
  self.frames += 1
  if self.frames > self.max_frames {
    let t = self.cur()
    raise ParseErrorExpr::ParseErrExpr(
      "expression is too deeply nested",
      t.line,
      t.col,
    )
  }
}

///|
fn Parser::leave(self : Parser) -> Unit {
  self.frames -= 1
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
  self.at_expr0 = true
  if self.at_kw("let") {
    return self.parse_let()
  }
  let first = self.parse_expr()
  if self.eat_op(";") {
    let items : Array[ENode] = [first]
    while !(self.cur().kind is TkEOF || self.at_op("}")) {
      if self.at_kw("let") {
        items.push(self.parse_let())
      } else {
        items.push(self.parse_expr())
      }
      if !self.eat_op(";") {
        break
      }
    }
    return ESeq(items, node_line(first), node_col(first))
  }
  first
}

///|
// let x = e; let y = e; rest — declarations chained via ELet.
fn Parser::parse_let(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_let_inner()
  self.leave()
  r
}

///|
fn Parser::parse_let_inner(self : Parser) -> ENode raise ParseErrorExpr {
  let kw = self.toks[self.pos]
  self.pos += 1 // consume `let`
  if self.cur().kind is TkIdent {
    let name = self.cur().text
    if name == "$env" {
      let e = self.err("cannot declare '$env'")
      e
    } else {
      self.pos += 1
      self.expect_op("=")
      let value = self.parse_expr()
      self.expect_op(";")
      let rest = self.parse_program_rest()
      ELet(name, value, rest, kw.line, kw.col)
    }
  } else {
    self.err("expected identifier after 'let'")
  }
}

///|
// rest of a program after a `let` declaration.
fn Parser::parse_program_rest(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_program_rest_inner()
  self.leave()
  r
}

///|
fn Parser::parse_program_rest_inner(
  self : Parser,
) -> ENode raise ParseErrorExpr {
  self.at_expr0 = true
  if self.at_kw("let") {
    return self.parse_let()
  }
  let first = self.parse_expr()
  if self.eat_op(";") {
    let items : Array[ENode] = [first]
    while !(self.cur().kind is TkEOF || self.at_op("}")) {
      if self.at_kw("let") {
        items.push(self.parse_let())
      } else {
        items.push(self.parse_expr())
      }
      if !self.eat_op(";") {
        break
      }
    }
    return ESeq(items, node_line(first), node_col(first))
  }
  first
}

///|
/// Pratt expression parsing: starts at the lowest precedence (pipe),
/// if/else and ternary handled above/below the binary loop. A `let`
/// declaration may begin any precedence-0 expression site.
fn Parser::parse_expr(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_expr_inner()
  self.leave()
  r
}

///|
fn Parser::parse_expr_inner(self : Parser) -> ENode raise ParseErrorExpr {
  self.at_expr0 = true
  if self.at_kw("let") {
    return self.parse_let()
  }
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
    return ECond(cond_e, None, Some(alt), node_line(cond_e), node_col(cond_e))
  }
  let consequent = self.parse_expr()
  self.expect_op(":")
  let alt = self.parse_expr()
  ECond(
    cond_e,
    Some(consequent),
    Some(alt),
    node_line(cond_e),
    node_col(cond_e),
  )
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
  self.enter()
  let r = self.parse_binary_inner(min_prec)
  self.leave()
  r
}

///|
fn Parser::parse_binary_inner(
  self : Parser,
  min_prec : Int,
) -> ENode raise ParseErrorExpr {
  // Only precedence-0 sites accept `if` at expression start; deeper
  // operand parses clear the flag so `1 + if …` errors.
  self.at_expr0 = min_prec == 0
  let mut left = self.parse_unary()
  while true {
    // not-prefixed suffix operators: `not in`, `not matches`, …
    if self.at_kw("not") {
      match self.peek().kind {
        TkKeyword =>
          match self.peek().text {
            "in" | "matches" | "contains" | "startsWith" | "endsWith" => {
              self.pos += 1 // consume `not`
              let not_tok = self.toks[self.pos - 1]
              let op = self.cur().text
              self.pos += 1
              let op_tok = self.toks[self.pos - 1]
              let prec = binary_prec(op)
              if prec < min_prec {
                self.pos -= 2
                break
              }
              let right = self.parse_binary(prec + 1)
              left = EUnary(
                "not",
                EBinary(op, left, right, op_tok.line, op_tok.col),
                not_tok.line,
                not_tok.col,
              )
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
    let op_tok = self.toks[self.pos - 1]
    if op == "|" {
      // Pipe: `left | fn(args)` → `fn(left, args...)`. expr requires a
      // parenthesized call on the right (bare `| fn` and `| x.m()` are
      // parse errors), and the subject takes call-argument 0 — so an
      // aggregate's first explicit argument is its predicate and must
      // parse in predicate context (expr's parseCall(ident, [left]).
      if self.cur().kind is TkIdent &&
        self.peek().kind is TkOperator &&
        self.peek().text == "(" {
        let name = self.cur().text
        let name_line = self.cur().line
        let name_col = self.cur().col
        self.pos += 1
        let name_node = EIdent(name, name_line, name_col)
        let args = self.parse_call_args_for(name_node, true)
        let all : Array[ENode] = [left]
        for a in args {
          all.push(a)
        }
        left = ECall(name_node, all, name_line, name_col)
        continue
      }
      return self.err("unexpected token after '|' (expected a call)")
    }
    let right = if right_assoc(op) {
      self.parse_binary(prec)
    } else {
      self.parse_binary(prec + 1)
    }
    left = EBinary(op, left, right, op_tok.line, op_tok.col)
    // expr forbids mixing `??` with any other binary operator at the
    // same level (`1 ?? 2 + 3`); parentheses or chained `??` are fine.
    if op == "??" {
      match op_of(self.cur()) {
        Some(next) if next != "??" =>
          return self.err(
            "Operator (" +
            next +
            ") and coalesce expressions (??) cannot be mixed. Wrap either by parentheses.",
          )
        _ => ()
      }
    }
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
        let op2_tok = self.toks[self.pos - 1]
        let mid = left_midpoint(left)
        let right2 = self.parse_binary(binary_prec(op2) + 1)
        left = EBinary(
          "and",
          left,
          EBinary(op2, mid, right2, op2_tok.line, op2_tok.col),
          op2_tok.line,
          op2_tok.col,
        )
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
    EBinary(_, _, r, _, _) => r
    other => other
  }
}

///|
fn Parser::parse_unary(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_unary_inner()
  self.leave()
  r
}

///|
fn Parser::parse_unary_inner(self : Parser) -> ENode raise ParseErrorExpr {
  if self.at_op("!") {
    self.pos += 1
    // expr unary precedence: `not`/`!` 50, `-`/`+` 90 — below `**`/`^`
    // (100), so `-2**2` = -(2**2) and `2**-2` is legal.
    let bang = self.toks[self.pos - 1]
    return EUnary("!", self.parse_binary(50), bang.line, bang.col)
  }
  if self.at_op("-") {
    self.pos += 1
    let minus = self.toks[self.pos - 1]
    return EUnary("-", self.parse_binary(90), minus.line, minus.col)
  }
  if self.at_op("+") {
    self.pos += 1
    return self.parse_binary(90)
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
          let not2 = self.toks[self.pos - 1]
          return EUnary("not", self.parse_binary(50), not2.line, not2.col)
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
        let base_l = node_line(e)
        let base_c = node_col(e)
        if self.at_op("(") {
          let args = self.parse_call_args()
          let callee = EMember(e, name, false, base_l, base_c)
          e = ECall(callee, args, base_l, base_c)
        } else {
          e = EMember(e, name, false, base_l, base_c)
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
        e = EIndex(e, idx, node_line(e), node_col(e)) // nil-safe by
        // evaluation semantics
        continue
      }
      if self.cur().kind is TkIdent {
        let name = self.cur().text
        self.pos += 1
        e = EMember(e, name, true, node_line(e), node_col(e))
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
        e = ESlice(e, None, to, node_line(e), node_col(e))
        continue
      }
      if self.at_op(".") {
        // Bracket predicate `items[.expr]`: Jexl's relative filter —
        // the predicate evaluates against each element. expr-lang has
        // no bracket form (bare '.' after '[' is a parse error there),
        // so this is mbel's documented Jexl-compat extension; lowered
        // to the legacy relative FilterExpression, which both engines
        // already execute (docs/expr-gap-analysis.md).
        let saved = self.in_predicate
        self.in_predicate = true
        let inner = self.parse_expr()
        self.in_predicate = saved
        self.expect_op("]")
        e = EIndex(
          e,
          EPred(inner, node_line(inner), node_col(inner)),
          node_line(e),
          node_col(e),
        )
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
        e = ESlice(e, Some(idx), to, node_line(e), node_col(e))
        continue
      }
      self.expect_op("]")
      e = EIndex(e, idx, node_line(e), node_col(e))
      continue
    }
    if self.at_op("(") {
      let args = self.parse_call_args_for(e, false)
      e = ECall(e, args, node_line(e), node_col(e))
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
  self.parse_call_args_for(ENil(1, 1), false)
}

///|
/// Parses `(args)`; when the callee is an aggregate function, the
/// predicate-position argument parses in predicate context (bare
/// `.field` access allowed), mirroring expr's predicate-position rule:
/// argument 1 for a direct call, argument 0 when the subject arrives
/// through a pipe (it takes call-argument 0).
fn Parser::parse_call_args_for(
  self : Parser,
  callee : ENode,
  piped_subject : Bool,
) -> Array[ENode] raise ParseErrorExpr {
  self.expect_op("(")
  let args : Array[ENode] = []
  if self.eat_op(")") {
    return args
  }
  let callee_name = match callee {
    EIdent(f, _, _) => f
    _ => ""
  }
  let mut arg_idx = 0
  while true {
    let saved = self.in_predicate
    if @grammar.is_aggregate(callee_name) &&
      ((piped_subject && arg_idx == 0) || (!piped_subject && arg_idx == 1)) {
      self.in_predicate = true
    }
    if self.at_op("{") && self.brace_starts_map() {
      args.push(self.parse_map_literal())
    } else if self.at_op("{") {
      self.pos += 1
      let inner = self.parse_expr()
      self.expect_op("}")
      args.push(EPred(inner, node_line(inner), node_col(inner)))
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
  let ob = self.toks[self.pos]
  self.expect_op("{")
  let pairs : Array[(ENode, ENode)] = []
  if self.eat_op("}") {
    return EMap(pairs, ob.line, ob.col)
  }
  while true {
    let key : ENode = match self.cur().kind {
      TkIdent => {
        let kt = self.cur()
        EIdent(kt.text, kt.line, kt.col)
      }
      TkStr => {
        let kt = self.cur()
        EStr(kt.text, kt.line, kt.col)
      }
      TkInt => {
        let kt = self.cur()
        int_from_text_at(kt.text, kt.line, kt.col)
      }
      TkFloat => {
        let kt = self.cur()
        float_from_text(kt.text, kt.line, kt.col)
      }
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
  EMap(pairs, ob.line, ob.col)
}

///|
fn Parser::parse_primary(self : Parser) -> ENode raise ParseErrorExpr {
  let t = self.cur()
  match t.kind {
    TkInt => {
      let text = t.text
      let line = t.line
      let col = t.col
      self.pos += 1
      int_from_text_at(text, line, col)
    }
    TkFloat => {
      let text = t.text
      let line = t.line
      let col = t.col
      self.pos += 1
      float_from_text(text, line, col)
    }
    TkStr => {
      let sv = t.text
      let line = t.line
      let col = t.col
      self.pos += 1
      EStr(sv, line, col)
    }
    TkBytes => {
      let bv = t.text
      let line = t.line
      let col = t.col
      self.pos += 1
      EBytes(bytes_from_str(bv), line, col)
    }
    TkPointer => {
      let text = t.text
      // expr supports exactly the pointers `#`, `#index`, `#acc`; any
      // other suffix (`#age` etc.) is a compile error in expr. Pointers
      // are also predicate-only: outside one, expr's parser rejects
      // them as unexpected tokens (parsePrimary gates on depth > 0).
      if text != "#" && text != "#index" && text != "#acc" {
        let e = self.err("unknown pointer '" + text + "'")
        e
      } else if !self.in_predicate {
        let e = self.err("unexpected token '" + text + "'")
        e
      } else {
        self.pos += 1
        EPointer(text, t.line, t.col)
      }
    }
    TkKeyword =>
      match t.text {
        "true" => {
          self.pos += 1
          EBool(true, t.line, t.col)
        }
        "false" => {
          self.pos += 1
          EBool(false, t.line, t.col)
        }
        "nil" => {
          self.pos += 1
          ENil(t.line, t.col)
        }
        "if" =>
          if self.at_expr0 {
            self.parse_if()
          } else {
            // `if` is only accepted at precedence-0 expression starts
            let e = self.err("unexpected keyword 'if'")
            e
          }
        other_kw => {
          let _ = self.err("unexpected keyword '" + other_kw + "'")
          ENil(t.line, t.col)
        }
      }
    TkIdent => {
      let name = t.text
      let line = t.line
      let col = t.col
      self.pos += 1
      // predicate-relative member: `.name` sugar handled via in_predicate
      // flag at the dot site; bare identifiers are plain.
      if self.in_predicate && self.at_op(".") {
        // `.field` inside a predicate = pointer member access
        let dot = self.toks[self.pos]
        self.pos += 1
        if self.cur().kind is TkIdent {
          let f = self.cur().text
          self.pos += 1
          return EMember(
            EPointer("#", dot.line, dot.col),
            f,
            false,
            dot.line,
            dot.col,
          )
        }
        let _ = self.err("expected identifier after '.' in predicate")
      }
      EIdent(name, line, col)
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
        let dot = self.toks[self.pos]
        self.pos += 1
        if self.cur().kind is TkIdent {
          let f = self.cur().text
          self.pos += 1
          EMember(EPointer("#", dot.line, dot.col), f, false, dot.line, dot.col)
        } else {
          let _ = self.err("expected identifier after '.' in predicate")
          ENil(t.line, t.col)
        }
      } else {
        let _ = self.err("unexpected token '" + t.text + "'")
        ENil(t.line, t.col)
      }
    TkEOF => self.err("unexpected end of expression")
  }
}

///|
fn Parser::parse_array_literal(self : Parser) -> ENode raise ParseErrorExpr {
  let ob = self.toks[self.pos]
  self.expect_op("[")
  let items : Array[ENode] = []
  if self.eat_op("]") {
    return EArray(items, ob.line, ob.col)
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
  EArray(items, ob.line, ob.col)
}

///|
/// if cond { seq } else { seq } — both braces and `else` are required
/// (expr parity); else-if chains nest naturally. Each brace body is a
/// full sequence expression: lets and `;`-separated exprs allowed.
fn Parser::parse_if(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_if_inner()
  self.leave()
  r
}

///|
fn Parser::parse_if_inner(self : Parser) -> ENode raise ParseErrorExpr {
  self.pos += 1 // consume `if`
  let cond = self.parse_expr()
  self.expect_op("{")
  let then = self.parse_block_body()
  self.expect_op("}")
  if !self.at_kw("else") {
    let e = self.err("expected 'else'")
    e
  } else {
    self.pos += 1
    if self.at_kw("if") {
      let nested = self.parse_if()
      return ECond(
        cond,
        Some(then),
        Some(nested),
        node_line(cond),
        node_col(cond),
      )
    }
    self.expect_op("{")
    let alt = self.parse_block_body()
    self.expect_op("}")
    ECond(cond, Some(then), Some(alt), node_line(cond), node_col(cond))
  }
}

///|
/// Parses a braced block body: expr (';' expr)* (or a leading `let`),
/// stopping at the closing brace; a trailing `;` is tolerated.
fn Parser::parse_block_body(self : Parser) -> ENode raise ParseErrorExpr {
  self.enter()
  let r = self.parse_block_body_inner()
  self.leave()
  r
}

///|
fn Parser::parse_block_body_inner(self : Parser) -> ENode raise ParseErrorExpr {
  self.at_expr0 = true
  let items : Array[ENode] = []
  if self.at_kw("let") {
    items.push(self.parse_let())
  } else {
    items.push(self.parse_expr())
  }
  while self.at_op(";") {
    self.pos += 1
    if self.at_op("}") {
      break
    }
    if self.at_kw("let") {
      items.push(self.parse_let())
    } else {
      items.push(self.parse_expr())
    }
  }
  if items.length() == 1 {
    items[0]
  } else {
    ESeq(items, node_line(items[0]), node_col(items[0]))
  }
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
fn int_from_text(text : String) -> ENode raise ParseErrorExpr {
  int_from_text_at(text, 1, 1)
}

///|
/// Parses an integer token ("int:<digits>" folded by the lexer, or raw
/// digits), rejecting values beyond int64 range like expr does.
fn int_from_text_at(
  text : String,
  line : Int,
  col : Int,
) -> ENode raise ParseErrorExpr {
  let chars = text.to_array()
  let digits = if chars.length() > 4 && chars[0] == 'i' && chars[1] == 'n' {
    text[4:].to_owned()
  } else {
    text
  }
  match parse_int64_checked(digits) {
    Some(v) => EInt(v, line, col)
    None =>
      raise ParseErrorExpr::ParseErrExpr(
        "invalid integer literal: value out of range", line, col,
      )
  }
}

///|
/// Decimal digits to Int64 with overflow detection (expr rejects
/// literals above MaxInt64 at parse time).
fn parse_int64_checked(digits : String) -> Int64? {
  let chars = digits.to_array()
  let mut v = 0L
  for c in chars {
    if c < '0' || c > '9' {
      return None
    }
    let d = (c.to_int() - '0'.to_int()).to_int64()
    if v > (9223372036854775807L - d) / 10L {
      return None
    }
    v = v * 10L + d
  }
  Some(v)
}

///|
fn float_from_text(text : String, line : Int, col : Int) -> ENode {
  let chars = text.to_array()
  if chars.length() > 6 && chars[0] == 'f' && chars[1] == 'l' {
    EFloat(parse_float_str(text[6:].to_owned()), line, col)
  } else {
    EFloat(parse_float_str(text), line, col)
  }
}
