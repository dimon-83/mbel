// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// evaluator package: tree-walking evaluation of parsed expressions.
//
// Ported from Jexl's lib/evaluator/Evaluator.js + handlers.js.
// MoonBit is synchronous, so the JS Promise machinery (Promise and
// PromiseSync) collapses into plain direct evaluation. The grammar
// operator tables carry eval functions, exactly like Jexl's
// grammar.js elements map.

///|
/// Evaluation error carrying a Jexl-style message.
pub(all) suberror EvalError {
  EvalErr(String)
}

///|
/// A transform or function: receives pre-evaluated arguments (the
/// transform subject is argument 0, matching Jexl) and returns a
/// value. May raise — Jexl transforms/functions can throw.
pub type FnA = (Array[@ast.Value]) -> @ast.Value raise EvalError

///|
/// A lazy operand: evaluating it yields the operand's value, and may
/// raise. Powers on-demand (manual-eval) operators.
pub type Lazy = () -> @ast.Value raise EvalError

///|
/// An on-demand operator: receives two lazy operands and decides
/// itself whether to evaluate them.
pub type FnL = (Lazy, Lazy) -> @ast.Value raise EvalError

///|
/// A binary operator implementation. May raise (custom operators can
/// fail like user transforms).
pub type FnB = (@ast.Value, @ast.Value) -> @ast.Value raise EvalError

///|
/// A unary operator implementation. May raise.
pub type FnU = (@ast.Value) -> @ast.Value raise EvalError

///|
/// The operator/function registry, mirroring Jexl's grammar object:
///   transforms/functions: named pools (seeded empty by default)
///   binary_ops/unary_ops: symbol → eval function, seeded with the
///     default grammar operators
pub(all) struct Grammar {
  transforms : Array[(String, FnA)]
  functions : Array[(String, FnA)]
  binary_ops : Array[(String, FnB)]
  on_demand_ops : Array[(String, FnL)]
  unary_ops : Array[(String, FnU)]
  // Compiled-regex cache for the `matches` operator (expr compiles
  // string literals at check time; we cache at eval time).
  mut regex_cache : Array[(String, @string.Regex)]
  mut regex_failed : Array[String]
}

///|
/// Builds the default grammar: the built-in operator set with Jexl
/// eval semantics, and empty transforms/functions pools.
pub fn default_grammar() -> Grammar {
  {
    transforms: [],
    functions: [],
    binary_ops: default_binary_ops(),
    on_demand_ops: [
      (
        "&&",
        fn(l : Lazy, r : Lazy) -> @ast.Value raise EvalError {
          let lv = l()
          if truthy(lv) {
            r()
          } else {
            lv
          }
        },
      ),
      (
        "||",
        fn(l : Lazy, r : Lazy) -> @ast.Value raise EvalError {
          let lv = l()
          if truthy(lv) {
            lv
          } else {
            r()
          }
        },
      ),
      // expr's ?? — take the right side only when the left is nil
      // (mbel also treats Jexl's undefined as nil here).
      (
        "??",
        fn(l : Lazy, r : Lazy) -> @ast.Value raise EvalError {
          let lv = l()
          match lv {
            @ast.NullVal | @ast.UndefVal => r()
            _ => lv
          }
        },
      ),
    ],
    unary_ops: [
      ("!", fn(v) { @ast.BoolVal(!truthy(v)) }),
      // expr keyword `not` lowers to a unary op as well.
      ("not", fn(v) { @ast.BoolVal(!truthy(v)) }),
      // expr unary minus (preserves type: -int wraps Int64; -float is
      // double negation — Jexl folded negatives at the lexer, so this
      // op is only reachable from the expr front end).
      (
        "-",
        fn(v) {
          match v {
            @ast.IntVal(i) => @ast.IntVal(-i)
            other => @ast.NumVal(-to_number(other))
          }
        },
      ),
    ],
    regex_cache: [],
    regex_failed: [],
  }
}

///|
/// Finds a named function in a registry list.
fn find_fn(list : Array[(String, FnA)], name : String) -> FnA? {
  for entry in list {
    let (n, f) = entry
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
fn find_bin(list : Array[(String, FnB)], name : String) -> FnB? {
  for entry in list {
    let (n, f) = entry
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
fn find_lazy(list : Array[(String, FnL)], name : String) -> FnL? {
  for entry in list {
    let (n, f) = entry
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
fn find_un(list : Array[(String, FnU)], name : String) -> FnU? {
  for entry in list {
    let (n, f) = entry
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
fn default_binary_ops() -> Array[(String, FnB)] {
  [
    ("+", plus),
    ("-", minus),
    ("*", times),
    ("/", divide),
    ("//", int_divide),
    ("%", rem),
    ("^", power),
    ("==", eq),
    ("!=", neq),
    (">", fn(a, b) { @ast.BoolVal(compare(">", a, b)) }),
    (">=", fn(a, b) { @ast.BoolVal(compare(">=", a, b)) }),
    ("<", fn(a, b) { @ast.BoolVal(compare("<", a, b)) }),
    ("<=", fn(a, b) { @ast.BoolVal(compare("<=", a, b)) }),
    ("in", in_op),
    ("..", range_op),
    // expr string operators (infix `contains`/`startsWith`/`endsWith`):
    // nil-safe — a nil operand yields false, not an error.
    ("contains", contains_op),
    ("startsWith", starts_with_op),
    ("endsWith", ends_with_op),
  ]
}

///|
fn contains_op(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  str_bin_op("contains", a, b)
}

///|
fn starts_with_op(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  str_bin_op("startsWith", a, b)
}

///|
fn ends_with_op(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  str_bin_op("endsWith", a, b)
}

///|
fn str_bin_op(
  op : String,
  a : @ast.Value,
  b : @ast.Value,
) -> @ast.Value raise EvalError {
  match (a, b) {
    (@ast.StrVal(s), @ast.StrVal(sub)) => {
      let idx = index_of(s, sub)
      let slen = s.to_array().length()
      let sublen = sub.to_array().length()
      match op {
        "contains" => @ast.BoolVal(idx >= 0)
        "startsWith" => @ast.BoolVal(idx == 0)
        _ => @ast.BoolVal(idx >= 0 && idx + sublen == slen)
      }
    }
    (@ast.NullVal | @ast.UndefVal, _) | (_, @ast.NullVal | @ast.UndefVal) =>
      @ast.BoolVal(false)
    _ =>
      raise EvalError::EvalErr("operator '" + op + "' requires string operands")
  }
}

///|
/// expr's `..` range: both bounds must be integers; the element count
/// is charged against the step budget so `1..100000000` fails fast.
fn range_op(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  let x = to_number(a)
  let y = to_number(b)
  if x != x.floor() || y != y.floor() || x != x || y != y {
    raise EvalError::EvalErr("range bounds must be integers")
  }
  let lo = x.to_int()
  let hi = y.to_int()
  if hi - lo > 1000000 {
    // Mirrors expr's DefaultMemoryBudget (1e6 elements).
    raise EvalError::EvalErr("memory budget exceeded")
  }
  // expr ranges are integer arrays when both bounds are typed ints;
  // legacy (NumVal) bounds keep the double-element behavior.
  let typed = match (a, b) {
    (@ast.IntVal(_), @ast.IntVal(_)) => true
    (_, _) => false
  }
  let out : Array[@ast.Value] = []
  let mut i = lo
  while i <= hi {
    if typed {
      out.push(@ast.IntVal(i.to_int64()))
    } else {
      out.push(@ast.NumVal(i.to_double()))
    }
    i += 1
  }
  @ast.ArrayVal(out)
}

///|
/// Cached regex match against a grammar's cache.
fn grammar_regex_match(
  g : Grammar,
  s : String,
  pattern : String,
) -> Bool raise EvalError {
  for pair in g.regex_cache {
    let (p, re) = pair
    if p == pattern {
      return re.execute(s) is Some(_)
    }
  }
  for p in g.regex_failed {
    if p == pattern {
      raise EvalError::EvalErr("invalid regex: " + pattern)
    }
  }
  let re = @string.Regex::string(pattern) catch {
    _ => {
      g.regex_failed.push(pattern)
      raise EvalError::EvalErr("invalid regex: " + pattern)
    }
  }
  g.regex_cache.push((pattern, re))
  re.execute(s) is Some(_)
}

///|
/// JS `+`: string concatenation when either operand is a string,
/// otherwise numeric addition.

///|
/// JS `+`: concatenation when either operand is string-like. JS first
/// coerces operands via ToPrimitive, and arrays/objects become
/// strings ("1,2", "[object Object]"), so any array/object/string
/// operand makes `+` a concatenation. Otherwise numeric addition.
pub fn plus(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  if typed_bin(a, b) {
    match typed_int_arith("+", a, b) {
      Some(v) => return v
      None => ()
    }
    if numeric_val(a) && numeric_val(b) {
      // int + float -> float64 (expr promotion)
      return @ast.NumVal(to_number(a) + to_number(b))
    }
    raise typed_mismatch("+", a, b)
  }
  if concat_like(a) || concat_like(b) {
    @ast.StrVal(to_string(a) + to_string(b))
  } else {
    @ast.NumVal(to_number(a) + to_number(b))
  }
}

///|
fn concat_like(v : @ast.Value) -> Bool {
  match v {
    @ast.StrVal(_) | @ast.ArrayVal(_) | @ast.ObjectVal(_) => true
    _ => false
  }
}

///|
fn minus(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  if typed_bin(a, b) {
    match typed_int_arith("-", a, b) {
      Some(v) => return v
      None => ()
    }
    if numeric_val(a) && numeric_val(b) {
      return @ast.NumVal(to_number(a) - to_number(b))
    }
    raise typed_mismatch("-", a, b)
  }
  @ast.NumVal(to_number(a) - to_number(b))
}

///|
fn times(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  if typed_bin(a, b) {
    match typed_int_arith("*", a, b) {
      Some(v) => return v
      None => ()
    }
    if numeric_val(a) && numeric_val(b) {
      return @ast.NumVal(to_number(a) * to_number(b))
    }
    raise typed_mismatch("*", a, b)
  }
  @ast.NumVal(to_number(a) * to_number(b))
}

///|
fn divide(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  // expr: `/` is always float division (7/2 = 3.5, 1/0 = +Inf); no
  // divide-by-zero error. Non-numeric typed operands raise.
  if typed_bin(a, b) && !(numeric_val(a) && numeric_val(b)) {
    raise typed_mismatch("/", a, b)
  }
  @ast.NumVal(to_number(a) / to_number(b))
}

///|
/// JS `//` — Math.floor division.
fn int_divide(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.NumVal((to_number(a) / to_number(b)).floor())
}

///|
/// JS `%` — remainder with the sign of the dividend.
fn rem(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  if typed_bin(a, b) {
    // expr: `%` is integer-only (Go semantics, sign of dividend);
    // %0 is the single divide-by-zero error.
    match (a, b) {
      (@ast.IntVal(x), @ast.IntVal(y)) =>
        if y == 0L {
          raise EvalError::EvalErr("integer divide by zero")
        } else {
          return @ast.IntVal(x % y)
        }
      (_, _) => ()
    }
    if numeric_val(a) && numeric_val(b) {
      raise typed_mismatch("%", a, b)
    }
    raise typed_mismatch("%", a, b)
  }
  @ast.NumVal(remainder(to_number(a), to_number(b)))
}

///|
/// JS `^` — Math.pow.
fn power(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.NumVal(to_number(a).pow(to_number(b)))
}

///|
/// JS `==` / `!=` — loose equality (typed/expr equality when an
/// IntVal is involved: numerics promote, cross-kind is false).
fn eq(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.BoolVal(if typed_bin(a, b) { typed_eq(a, b) } else { loose_eq(a, b) })
}

///|
fn neq(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.BoolVal(if typed_bin(a, b) { !typed_eq(a, b) } else { !loose_eq(a, b) })
}

///|
/// JS `in`: substring check on strings, strict element match on arrays,
/// false for anything else.
fn in_op(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  match b {
    @ast.StrVal(s) => @ast.BoolVal(index_of(s, to_string(a)) != -1)
    @ast.ArrayVal(xs) => {
      let mut found = false
      for elem in xs {
        if strict_eq(elem, a) {
          found = true
          break
        }
      }
      @ast.BoolVal(found)
    }
    _ => @ast.BoolVal(false)
  }
}

// --- Value access helpers ---

///|
/// expr `subject[from:to]` slicing — shared by both engines. Bounds
/// follow expr's runtime: negative values normalize to `len + x`, both
/// clamp into [0, len], and `from > to` collapses to empty. Omitted
/// bounds slice to the ends; arrays and strings are supported (string
/// slicing is character-based in mbel; expr slices bytes — ASCII
/// results coincide, non-ASCII divergence documented).
pub fn slice_value(
  subject : @ast.Value,
  from : @ast.Value?,
  to : @ast.Value?,
) -> @ast.Value raise EvalError {
  let f = match from {
    None | Some(@ast.UndefVal) | Some(@ast.NullVal) => None
    Some(v) => Some(bound_int(v))
  }
  let t = match to {
    None | Some(@ast.UndefVal) | Some(@ast.NullVal) => None
    Some(v) => Some(bound_int(v))
  }
  match subject {
    @ast.ArrayVal(xs) => {
      let n = xs.length()
      let f0 = clamp_bound(
        match f {
          Some(x) => x
          None => 0
        },
        n,
      )
      let t0 = clamp_bound(
        match t {
          Some(x) => x
          None => n
        },
        n,
      )
      let start = if f0 > t0 { t0 } else { f0 }
      let out : Array[@ast.Value] = []
      let mut i = start
      while i < t0 {
        out.push(xs[i])
        i += 1
      }
      @ast.ArrayVal(out)
    }
    @ast.StrVal(s) => {
      let chars = s.to_array()
      let n = chars.length()
      let f0 = clamp_bound(
        match f {
          Some(x) => x
          None => 0
        },
        n,
      )
      let t0 = clamp_bound(
        match t {
          Some(x) => x
          None => n
        },
        n,
      )
      let start = if f0 > t0 { t0 } else { f0 }
      let out : Array[Char] = []
      let mut i = start
      while i < t0 {
        out.push(chars[i])
        i += 1
      }
      @ast.StrVal(String::from_array(out))
    }
    @ast.BytesVal(b) => {
      // byte slices keep byte semantics (expr: []byte slices)
      let n = b.length()
      let f0 = clamp_bound(
        match f {
          Some(x) => x
          None => 0
        },
        n,
      )
      let t0 = clamp_bound(
        match t {
          Some(x) => x
          None => n
        },
        n,
      )
      let start = if f0 > t0 { t0 } else { f0 }
      let out : Array[Byte] = []
      let mut i = start
      while i < t0 {
        out.push(b[i])
        i += 1
      }
      @ast.BytesVal(Bytes::from_array(out))
    }
    _ => raise EvalError::EvalErr("cannot slice " + value_kind(subject))
  }
}

///|
/// A slice bound must be an integral number.
fn bound_int(v : @ast.Value) -> Int raise EvalError {
  match v {
    @ast.NumVal(d) =>
      if d != d.floor() || d != d {
        raise EvalError::EvalErr("slice bounds must be integers")
      } else {
        d.to_int()
      }
    @ast.IntVal(i) => i.to_int()
    _ => raise EvalError::EvalErr("slice bounds must be integers")
  }
}

///|
/// Clamps a slice bound into [0, n] after negative normalization.
fn clamp_bound(x : Int, n : Int) -> Int {
  let mut v = if x < 0 { n + x } else { x }
  if v < 0 {
    v = 0
  }
  if v > n {
    v = n
  }
  v
}

///|
/// Short value-kind name for error messages.
pub fn value_kind(v : @ast.Value) -> String {
  match v {
    @ast.BoolVal(_) => "boolean"
    @ast.NumVal(_) => "number"
    @ast.IntVal(_) => "int"
    @ast.StrVal(_) => "string"
    // expr's type() reports "array" for []byte too
    @ast.BytesVal(_) => "array"
    @ast.ArrayVal(_) => "array"
    @ast.ObjectVal(_) => "map"
    @ast.NullVal => "nil"
    @ast.UndefVal => "undefined"
  }
}

///|
/// JS property access: `subject[key]` for objects, arrays (length,
/// numeric string keys), and strings (length).
pub fn index_value(subject : @ast.Value, res : @ast.Value) -> @ast.Value {
  match (subject, res) {
    (@ast.ArrayVal(xs), @ast.NumVal(d)) => arr_index(xs, d)
    (@ast.ArrayVal(xs), @ast.IntVal(i)) => arr_index(xs, i.to_double())
    (@ast.ArrayVal(xs), @ast.StrVal(k)) => arr_str_key(xs, k)
    (@ast.ObjectVal(pairs), @ast.StrVal(k)) => key_of(pairs, k)
    (@ast.ObjectVal(pairs), @ast.NumVal(d)) =>
      if d == nan() || d != d {
        @ast.UndefVal
      } else {
        key_of(pairs, d.to_string())
      }
    (@ast.StrVal(s), @ast.NumVal(d)) => str_index(s, d)
    (@ast.StrVal(s), @ast.StrVal(k)) =>
      if k == "length" {
        @ast.NumVal(s.length().to_double())
      } else {
        @ast.UndefVal
      }
    // Byte indexing yields the byte as an int. expr supports negative
    // indices on []byte; mbel arrays stay JS-semantics (negative →
    // undefined) on the legacy path, but bytes are expr-only so they
    // follow expr's negative-normalized indexing.
    (@ast.BytesVal(b), @ast.NumVal(d)) => byte_index(b, d)
    (@ast.BytesVal(b), @ast.IntVal(i)) => byte_index(b, i.to_double())
    (_, _) => @ast.UndefVal
  }
}

///|
/// expr-style index over []byte: negative indices count from the end
/// (b"abc"[-1] = 99); out-of-range yields UndefVal (mbel nil-safe —
/// expr raises "index out of range").
fn byte_index(b : Bytes, d : Double) -> @ast.Value {
  if d != d || d != d.floor() {
    return @ast.UndefVal
  }
  let n = b.length()
  let mut i = d.to_int()
  if i < 0 {
    i = n + i
  }
  if i < 0 || i >= n {
    @ast.UndefVal
  } else {
    @ast.IntVal(b[i].to_int().to_int64())
  }
}

///|
fn arr_index(xs : Array[@ast.Value], d : Double) -> @ast.Value {
  if d != d || d < 0.0 || d != d.floor() {
    return @ast.UndefVal
  }
  let i = d.to_int()
  if i < 0 || i >= xs.length() {
    @ast.UndefVal
  } else {
    xs[i]
  }
}

///|
fn arr_str_key(xs : Array[@ast.Value], k : String) -> @ast.Value {
  if k == "length" {
    return @ast.NumVal(xs.length().to_double())
  }
  let d = parse_decimal(k)
  if d != d {
    return @ast.UndefVal
  }
  arr_index(xs, d)
}

///|
fn str_index(s : String, d : Double) -> @ast.Value {
  if d != d || d < 0.0 || d != d.floor() {
    return @ast.UndefVal
  }
  let i = d.to_int()
  let chars = s.to_array()
  if i < 0 || i >= chars.length() {
    @ast.UndefVal
  } else {
    @ast.StrVal(chars[i].to_string())
  }
}

///|
fn key_of(pairs : Array[(String, @ast.Value)], k : String) -> @ast.Value {
  for pair in pairs {
    let (key, v) = pair
    if key == k {
      return v
    }
  }
  @ast.UndefVal
}

///|
/// Default max evaluation depth, mirroring expr's nesting protection.
/// 0 disables the limit.
pub fn default_max_depth() -> Int {
  10000
}

///|
/// Default max evaluation steps (an eval-node visit), mirroring
/// expr's memory budget magnitude. 0 disables the limit.
pub fn default_max_steps() -> Int {
  1000000
}

///|
/// Shared step counter: relative filters evaluate their predicate per
/// element on a fresh Evaluator that shares this cell, so the whole
/// expression draws from one budget (expr's VM-wide memory budget).
pub(all) struct BudgetCell {
  mut steps : Int
}

///|
/// The Evaluator walks an AST and computes its value within a context.
/// A `rel_context` backs relative identifiers inside filters; the main
/// context resolves plain identifiers.
#warnings("-unused_mut")
pub struct Evaluator {
  grammar : Grammar
  context : @ast.Value
  rel_context : @ast.Value
  mut depth : Int
  max_depth : Int
  budget : BudgetCell
  max_steps : Int
  // Predicate slots (expr # / #index / #acc), set while evaluating a
  // predicate for aggregates; default to undefined elsewhere.
  mut slot_elem : @ast.Value
  mut slot_idx : Int
  mut slot_acc : @ast.Value
  // Lexical let-bindings (expr `let`/sequences): innermost last. Empty
  // for every legacy (Jexl) evaluation, so legacy behavior is unchanged.
  mut locals : Array[(String, @ast.Value)]
}

///|
pub fn new_evaluator(grammar : Grammar, context : @ast.Value) -> Evaluator {
  new_evaluator_limited(
    grammar,
    context,
    default_max_depth(),
    default_max_steps(),
  )
}

///|
pub fn new_evaluator_limited(
  grammar : Grammar,
  context : @ast.Value,
  max_depth : Int,
  max_steps : Int,
) -> Evaluator {
  {
    grammar,
    context,
    rel_context: context,
    depth: 0,
    max_depth,
    budget: { steps: 0 },
    max_steps,
    slot_elem: @ast.UndefVal,
    slot_idx: 0,
    slot_acc: @ast.UndefVal,
    locals: [],
  }
}

///|
pub fn new_relative_evaluator(
  grammar : Grammar,
  context : @ast.Value,
  rel_context : @ast.Value,
) -> Evaluator {
  {
    grammar,
    context,
    rel_context,
    depth: 0,
    max_depth: default_max_depth(),
    budget: { steps: 0 },
    max_steps: default_max_steps(),
    slot_elem: @ast.UndefVal,
    slot_idx: 0,
    slot_acc: @ast.UndefVal,
    locals: [],
  }
}

///|
/// Evaluates an AST node, returning its value. Mirrors Jexl's
/// `handlers[ast.type]` dispatch, wrapped in step/depth accounting:
/// every eval visit draws from the shared step budget, and recursion
/// depth is capped (mirroring expr's node + memory budgets).
pub fn Evaluator::eval(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  // Step budget is charged at ALLOCATION points only (array/object
  // literals, ranges, relative filters), mirroring expr's VM
  // memGrow — constant and arithmetic work is free.
  if self.max_depth > 0 {
    self.depth = self.depth + 1
    if self.depth > self.max_depth {
      self.depth = self.depth - 1
      raise EvalError::EvalErr(
        "expression is too deep (more than " +
        self.max_depth.to_string() +
        " levels)",
      )
    }
    let result = self.dispatch(ast) catch {
      err => {
        self.depth = self.depth - 1
        raise err
      }
    }
    self.depth = self.depth - 1
    return result
  }
  self.dispatch(ast)
}

///|
/// Charges `n` allocation units against the shared budget (expr's
/// memGrow analogue).
fn Evaluator::charge_alloc(self : Evaluator, n : Int) -> Unit raise EvalError {
  if self.max_steps > 0 {
    self.budget.steps = self.budget.steps + n
    if self.budget.steps > self.max_steps {
      raise EvalError::EvalErr("memory budget exceeded")
    }
  }
}

///|
fn Evaluator::dispatch(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  match ast.node_type {
    @ast.LiteralNode => ast.value
    @ast.IdentifierNode => self.eval_identifier(ast)
    @ast.BinaryExpressionNode => self.eval_binary(ast)
    @ast.UnaryExpressionNode => self.eval_unary(ast)
    @ast.ConditionalExpressionNode => self.eval_conditional(ast)
    @ast.ArrayLiteralNode => self.eval_array_literal(ast)
    @ast.ObjectLiteralNode => self.eval_object_literal(ast)
    @ast.FilterExpressionNode => self.eval_filter(ast)
    @ast.FunctionCallNode => self.eval_function_call(ast)
    @ast.PointerNode =>
      match ast.ident_name {
        "#" => self.slot_elem
        "#index" => @ast.NumVal(self.slot_idx.to_double())
        "#acc" => self.slot_acc
        _ => @ast.UndefVal
      }
    @ast.SequenceNode => self.eval_sequence(ast)
    @ast.VariableDeclaratorNode =>
      raise EvalError::EvalErr("variable declarator outside a sequence")
    @ast.SliceNode => self.eval_slice(ast)
  }
}

///|
/// Evaluates a sequence `a; b; c`: items run left to right, `let`
/// items bind into a fresh local scope for the rest of the sequence,
/// and the last expression's value is the sequence's value.
fn Evaluator::eval_sequence(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let base = self.locals.length()
  let mut result = @ast.UndefVal
  for item in ast.args {
    if item.node_type is @ast.VariableDeclaratorNode {
      let v = self.eval(item.args[0])
      self.locals.push((item.ident_name, v))
    } else {
      result = self.eval(item)
    }
  }
  while self.locals.length() > base {
    ignore(self.locals.pop())
  }
  result
}

///|
/// Evaluates a slice `subject[from:to]`; missing bounds slice to the
/// ends. Result arrays charge the step budget by element count.
fn Evaluator::eval_slice(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let subject = self.eval(ast.subject.unwrap())
  let from_v = match ast.slice_from {
    Some(f) => Some(self.eval(f))
    None => None
  }
  let to_v = match ast.slice_to {
    Some(t) => Some(self.eval(t))
    None => None
  }
  let result = slice_value(subject, from_v, to_v)
  match result {
    @ast.ArrayVal(xs) => self.charge_alloc(xs.length())
    _ => ()
  }
  result
}

///|
/// Innermost-first lookup of a lexical let-binding.
fn lookup_local(
  locals : Array[(String, @ast.Value)],
  name : String,
) -> @ast.Value? {
  let mut i = locals.length() - 1
  while i >= 0 {
    let (n, v) = locals[i]
    if n == name {
      return Some(v)
    }
    i -= 1
  }
  None
}

///|
/// Evaluates each AST in an array to a value array (evalArray).
pub fn Evaluator::eval_array(
  self : Evaluator,
  nodes : Array[@ast.AstNode],
) -> Array[@ast.Value] raise EvalError {
  let out : Array[@ast.Value] = []
  for node in nodes {
    out.push(self.eval(node))
  }
  out
}

// --- Node handlers (ported from evaluator/handlers.js) ---

///|
/// Resolves an Identifier: either a plain context key, a lexical
/// let-binding, or a drill-down through the evaluated `from`
/// expression (arrays unwrap to element 0).
fn Evaluator::eval_identifier(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  if ast.from is None {
    if !ast.relative {
      // `$env` is the whole context (expr: the environment value);
      // let-bound names shadow context keys.
      if ast.ident_name == "$env" {
        return self.context
      }
      match lookup_local(self.locals, ast.ident_name) {
        Some(v) => return v
        None => ()
      }
    }
    let ctx = if ast.relative { self.rel_context } else { self.context }
    return key_of_value(ctx, ast.ident_name)
  }
  let from = self.eval(ast.from.unwrap())
  fetch_from(from, ast.ident_name)
}

///|
/// Shared drill-down semantics (arrays unwrap to element 0) for both
/// engines.
fn fetch_from(from : @ast.Value, name : String) -> @ast.Value {
  match from {
    @ast.UndefVal | @ast.NullVal => @ast.UndefVal
    @ast.ArrayVal(xs) =>
      if xs.length() == 0 {
        @ast.UndefVal
      } else {
        key_of_value(xs[0], name)
      }
    _ => key_of_value(from, name)
  }
}

///|
/// Context property access used by identifiers. Mirrors JS `obj[key]`
/// on the value types Jexl resolves: objects get key lookups, strings
/// expose `length`, arrays expose `length` (elements via filters).
fn key_of_value(v : @ast.Value, key : String) -> @ast.Value {
  match v {
    @ast.ObjectVal(pairs) => key_of(pairs, key)
    @ast.StrVal(s) =>
      if key == "length" {
        @ast.NumVal(s.length().to_double())
      } else {
        @ast.UndefVal
      }
    @ast.ArrayVal(xs) =>
      if key == "length" {
        @ast.NumVal(xs.length().to_double())
      } else {
        @ast.UndefVal
      }
    _ => @ast.UndefVal
  }
}

///|
/// Evaluates a BinaryExpression. `&&` and `||` short-circuit like
/// Jexl's evalOnDemand operators: the right side is only evaluated
/// when needed, so errors there do not surface for falsy/truthy lefts.
fn Evaluator::eval_binary(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let op = ast.operator
  let left = ast.left.unwrap()
  let right = ast.right.unwrap()
  // Jexl consults evalOnDemand first: && and || (and any manual-eval
  // custom op) receive lazy operands and decide whether to evaluate.
  match find_lazy(self.grammar.on_demand_ops, op) {
    Some(f) => {
      let wrap_l : Lazy = fn() -> @ast.Value raise EvalError { self.eval(left) }
      let wrap_r : Lazy = fn() -> @ast.Value raise EvalError {
        self.eval(right)
      }
      f(wrap_l, wrap_r)
    }
    None => {
      let l = self.eval(left)
      let r = self.eval(right)
      if op == "matches" {
        let pattern = match r {
          @ast.StrVal(p) => p
          _ => raise EvalError::EvalErr("matches: pattern must be a string")
        }
        return @ast.BoolVal(
          grammar_regex_match(self.grammar, to_string(l), pattern),
        )
      }
      apply_binary_op(self.grammar, op, l, r)
    }
  }
}

///|
/// Shared eager binary dispatch — the single source of semantics for
/// both the tree-walk engine and the VM (which emit OpBinary for the
/// same operators). Matches is handled here too since it needs the
/// grammar's regex cache.
fn apply_binary_op(
  g : Grammar,
  op : String,
  l : @ast.Value,
  r : @ast.Value,
) -> @ast.Value raise EvalError {
  if op == "matches" {
    let pattern = match r {
      @ast.StrVal(p) => p
      _ => raise EvalError::EvalErr("matches: pattern must be a string")
    }
    return @ast.BoolVal(grammar_regex_match(g, to_string(l), pattern))
  }
  match find_bin(g.binary_ops, op) {
    Some(f) => f(l, r)
    None =>
      raise EvalError::EvalErr("Binary operator " + op + " is not defined")
  }
}

///|
/// Evaluates a UnaryExpression via the grammar's unary op eval.
fn Evaluator::eval_unary(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let op = ast.operator
  let right = self.eval(ast.right.unwrap())
  match find_un(self.grammar.unary_ops, op) {
    Some(f) => f(right)
    None => raise EvalError::EvalErr("Unary operator " + op + " is not defined")
  }
}

///|
/// Evaluates a ConditionalExpression: truthy test takes the consequent
/// (or the test value itself when no consequent is present, for the
/// `a ?: b` form); falsy takes the alternate.
fn Evaluator::eval_conditional(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let test_val = self.eval(ast.cond_test.unwrap())
  if truthy(test_val) {
    match ast.consequent {
      Some(node) => self.eval(node)
      None => test_val
    }
  } else {
    match ast.alternate {
      Some(node) => self.eval(node)
      None =>
        raise EvalError::EvalErr("Conditional expression has no alternate")
    }
  }
}

///|
fn Evaluator::eval_array_literal(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  self.charge_alloc(1 + ast.array_value.length())
  @ast.ArrayVal(self.eval_array(ast.array_value))
}

///|
fn Evaluator::eval_object_literal(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  self.charge_alloc(1 + ast.obj_value.length())
  let pairs : Array[(String, @ast.Value)] = []
  for kv in ast.obj_value {
    let (k, v) = kv
    pairs.push((k, self.eval(v)))
  }
  @ast.ObjectVal(pairs)
}

///|
/// Byte strings iterate as their int elements in aggregates and
/// relative filters (expr: []byte is a slice of uint8). Shared by the
/// Walk evaluator and the Vm runtime (same package).
fn bytes_elements(b : Bytes) -> Array[@ast.Value] {
  let out : Array[@ast.Value] = []
  for i in 0..<b.length() {
    out.push(@ast.IntVal(b[i].to_int().to_int64()))
  }
  out
}

///|
/// Evaluates a FilterExpression: relative filters run the expression
/// against each subject element (arrays stay arrays, other values get
/// wrapped); static filters index into the subject by the expression
/// result, or keep/drop the subject for boolean results.
fn Evaluator::eval_filter(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let subject = self.eval(ast.subject.unwrap())
  if ast.filter_relative {
    // Relative filtering allocates a result array proportional to the
    // subject — charge per element (expr memGrow semantics).
    let list : Array[@ast.Value] = match subject {
      @ast.ArrayVal(xs) => {
        self.charge_alloc(xs.length())
        xs
      }
      @ast.BytesVal(b) => {
        // bytes filter as their int elements (expr: []byte is a
        // uint8 slice); result arrays charge per element like arrays
        self.charge_alloc(b.length())
        bytes_elements(b)
      }
      @ast.UndefVal => []
      other => [other]
    }
    let results : Array[@ast.Value] = []
    for i in 0..<list.length() {
      let elem = list[i]
      // Element evaluators share the parent's step budget so a large
      // filtered array cannot amplify work past the limit; they also
      // inherit lexical let-bindings from the enclosing sequence.
      // Typed pointer slots mirror the aggregate runner: `#` and
      // `#index` resolve to the element and its position.
      let e = {
        grammar: self.grammar,
        context: self.context,
        rel_context: elem,
        depth: 0,
        max_depth: self.max_depth,
        budget: self.budget,
        max_steps: self.max_steps,
        slot_elem: elem,
        slot_idx: i,
        slot_acc: @ast.UndefVal,
        locals: self.locals,
      }
      if truthy(e.eval(ast.filter_expr.unwrap())) {
        results.push(elem)
      }
    }
    @ast.ArrayVal(results)
  } else {
    let res = self.eval(ast.filter_expr.unwrap())
    match res {
      @ast.BoolVal(b) => if b { subject } else { @ast.UndefVal }
      _ => index_value(subject, res)
    }
  }
}

///|
/// Evaluates a FunctionCall by looking the name up in its pool
/// (functions or transforms), evaluating the args, and invoking it.
fn Evaluator::eval_function_call(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  if ast.pool == "functions" && @grammar.is_aggregate(ast.func_name) {
    return self.eval_aggregate(ast)
  }
  let args = self.eval_array(ast.args)
  call_pool_function(self.grammar, ast.pool, ast.func_name, args)
}

///|
/// Walk-side aggregate invocation: evaluate the non-predicate args,
/// run the predicate AST on per-element evaluators with typed slots.
fn Evaluator::eval_aggregate(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let has_pred = ast.args.length() > 1 && ast.args[1].is_pred
  let values : Array[@ast.Value] = []
  for i in 0..<ast.args.length() {
    if i == 1 && has_pred {
      continue
    }
    values.push(self.eval(ast.args[i]))
  }
  let list : Array[@ast.Value] = match values.get(0) {
    Some(@ast.ArrayVal(xs)) => xs
    Some(@ast.BytesVal(b)) => bytes_elements(b)
    Some(@ast.UndefVal) | None => []
    Some(_) =>
      raise EvalError::EvalErr(
        ast.func_name + ": first argument must be an array",
      )
  }
  let extra = values[1:].to_array()
  if has_pred {
    let pred_ast = ast.args[1]
    let runner : PredRunner = fn(i, elem, acc) {
      let e = {
        grammar: self.grammar,
        context: self.context,
        rel_context: elem,
        depth: 0,
        max_depth: self.max_depth,
        budget: self.budget,
        max_steps: self.max_steps,
        slot_elem: elem,
        slot_idx: i,
        slot_acc: acc,
        locals: self.locals,
      }
      e.eval(pred_ast)
    }
    aggregate_call(ast.func_name, list, true, extra, runner)
  } else {
    aggregate_call(ast.func_name, list, false, extra, fn(_, _, _) {
      raise EvalError::EvalErr("aggregate: predicate required")
    })
  }
}

///|
/// Shared function/transform pool dispatch for both engines.
fn call_pool_function(
  g : Grammar,
  pool : String,
  name : String,
  args : Array[@ast.Value],
) -> @ast.Value raise EvalError {
  let pool_name = match pool {
    "functions" => "Jexl Function"
    "transforms" => "Transform"
    _ => raise EvalError::EvalErr("Corrupt AST: Pool '" + pool + "' not found")
  }
  let pool_fns = if pool == "functions" { g.functions } else { g.transforms }
  let f = match find_fn(pool_fns, name) {
    Some(f) => f
    None =>
      raise EvalError::EvalErr(pool_name + " " + name + " is not defined.")
  }
  f(args)
}
