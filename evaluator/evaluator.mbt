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
    unary_ops: [("!", fn(v) { @ast.BoolVal(!truthy(v)) })],
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
  ]
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
  let out : Array[@ast.Value] = []
  let mut i = lo
  while i <= hi {
    out.push(@ast.NumVal(i.to_double()))
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
  @ast.NumVal(to_number(a) - to_number(b))
}

///|
fn times(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.NumVal(to_number(a) * to_number(b))
}

///|
fn divide(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
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
  @ast.NumVal(remainder(to_number(a), to_number(b)))
}

///|
/// JS `^` — Math.pow.
fn power(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.NumVal(to_number(a).pow(to_number(b)))
}

///|
/// JS `==` / `!=` — loose equality.
fn eq(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.BoolVal(loose_eq(a, b))
}

///|
fn neq(a : @ast.Value, b : @ast.Value) -> @ast.Value raise EvalError {
  @ast.BoolVal(!loose_eq(a, b))
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
/// JS property access: `subject[key]` for objects, arrays (length,
/// numeric string keys), and strings (length).
pub fn index_value(subject : @ast.Value, res : @ast.Value) -> @ast.Value {
  match (subject, res) {
    (@ast.ArrayVal(xs), @ast.NumVal(d)) => arr_index(xs, d)
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
    (_, _) => @ast.UndefVal
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
pub struct Evaluator {
  grammar : Grammar
  context : @ast.Value
  rel_context : @ast.Value
  mut depth : Int
  max_depth : Int
  budget : BudgetCell
  max_steps : Int
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
  if self.max_steps > 0 {
    self.budget.steps = self.budget.steps + 1
    if self.budget.steps > self.max_steps {
      raise EvalError::EvalErr("memory budget exceeded")
    }
  }
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
  }
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
/// Resolves an Identifier: either a plain context key, or a drill-down
/// through the evaluated `from` expression (arrays unwrap to element 0).
fn Evaluator::eval_identifier(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  if ast.from is None {
    let ctx = if ast.relative { self.rel_context } else { self.context }
    return key_of_value(ctx, ast.ident_name)
  }
  let from = self.eval(ast.from.unwrap())
  match from {
    @ast.UndefVal | @ast.NullVal => @ast.UndefVal
    @ast.ArrayVal(xs) =>
      if xs.length() == 0 {
        @ast.UndefVal
      } else {
        key_of_value(xs[0], ast.ident_name)
      }
    _ => key_of_value(from, ast.ident_name)
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
      match find_bin(self.grammar.binary_ops, op) {
        Some(f) => f(l, r)
        None =>
          raise EvalError::EvalErr("Binary operator " + op + " is not defined")
      }
    }
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
  @ast.ArrayVal(self.eval_array(ast.array_value))
}

///|
fn Evaluator::eval_object_literal(
  self : Evaluator,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let pairs : Array[(String, @ast.Value)] = []
  for kv in ast.obj_value {
    let (k, v) = kv
    pairs.push((k, self.eval(v)))
  }
  @ast.ObjectVal(pairs)
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
    let list : Array[@ast.Value] = match subject {
      @ast.ArrayVal(xs) => xs
      @ast.UndefVal => []
      other => [other]
    }
    let results : Array[@ast.Value] = []
    for elem in list {
      // Element evaluators share the parent's step budget so a large
      // filtered array cannot amplify work past the limit.
      let e = {
        grammar: self.grammar,
        context: self.context,
        rel_context: elem,
        depth: 0,
        max_depth: self.max_depth,
        budget: self.budget,
        max_steps: self.max_steps,
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
  let pool_name = match ast.pool {
    "functions" => "Jexl Function"
    "transforms" => "Transform"
    _ =>
      raise EvalError::EvalErr("Corrupt AST: Pool '" + ast.pool + "' not found")
  }
  let pool = if ast.pool == "functions" {
    self.grammar.functions
  } else {
    self.grammar.transforms
  }
  let f = match find_fn(pool, ast.func_name) {
    Some(f) => f
    None =>
      raise EvalError::EvalErr(
        pool_name + " " + ast.func_name + " is not defined.",
      )
  }
  let args = self.eval_array(ast.args)
  f(args)
}
