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
/// A binary operator implementation.
pub type FnB = (@ast.Value, @ast.Value) -> @ast.Value

///|
/// A unary operator implementation.
pub type FnU = (@ast.Value) -> @ast.Value

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
          if truthy(lv) { r() } else { lv }
        },
      ),
      (
        "||",
        fn(l : Lazy, r : Lazy) -> @ast.Value raise EvalError {
          let lv = l()
          if truthy(lv) { lv } else { r() }
        },
      ),
    ],
    unary_ops: [("!", fn(v) { @ast.BoolVal(!truthy(v)) })],
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
  ]
}

///|
/// JS `+`: string concatenation when either operand is a string,
/// otherwise numeric addition.
fn plus(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  match (a, b) {
    (@ast.StrVal(x), _) => @ast.StrVal(x + to_string(b))
    (_, @ast.StrVal(y)) => @ast.StrVal(to_string(a) + y)
    (_, _) => @ast.NumVal(to_number(a) + to_number(b))
  }
}

///|
fn minus(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal(to_number(a) - to_number(b))
}

///|
fn times(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal(to_number(a) * to_number(b))
}

///|
fn divide(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal(to_number(a) / to_number(b))
}

///|
/// JS `//` — Math.floor division.
fn int_divide(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal((to_number(a) / to_number(b)).floor())
}

///|
/// JS `%` — remainder with the sign of the dividend.
fn rem(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal(remainder(to_number(a), to_number(b)))
}

///|
/// JS `^` — Math.pow.
fn power(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.NumVal(to_number(a).pow(to_number(b)))
}

///|
/// JS `==` / `!=` — loose equality.
fn eq(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.BoolVal(loose_eq(a, b))
}

///|
fn neq(a : @ast.Value, b : @ast.Value) -> @ast.Value {
  @ast.BoolVal(!loose_eq(a, b))
}

///|
/// JS `in`: substring check on strings, strict element match on arrays,
/// false for anything else.
fn in_op(a : @ast.Value, b : @ast.Value) -> @ast.Value {
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
/// The Evaluator walks an AST and computes its value within a context.
/// A `rel_context` backs relative identifiers inside filters; the main
/// context resolves plain identifiers.
pub struct Evaluator {
  grammar : Grammar
  context : @ast.Value
  rel_context : @ast.Value
}

///|
pub fn new_evaluator(grammar : Grammar, context : @ast.Value) -> Evaluator {
  { grammar, context, rel_context: context }
}

///|
pub fn new_relative_evaluator(
  grammar : Grammar,
  context : @ast.Value,
  rel_context : @ast.Value,
) -> Evaluator {
  { grammar, context, rel_context }
}

///|
/// Evaluates an AST node, returning its value.
/// Mirrors Jexl's `handlers[ast.type]` dispatch.
pub fn Evaluator::eval(
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
  match op {
    "&&" => {
      let l = self.eval(left)
      if truthy(l) {
        self.eval(right)
      } else {
        l
      }
    }
    "||" => {
      let l = self.eval(left)
      if truthy(l) {
        l
      } else {
        self.eval(right)
      }
    }
    _ => {
      let l = self.eval(left)
      let r = self.eval(right)
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
      let e = new_relative_evaluator(self.grammar, self.context, elem)
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
