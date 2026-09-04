// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// jexl package: top-level API — Jexl class.
//
// Ported from Jexl's lib/Jexl.js. An instance owns its element
// registry (operators can be added or removed per instance) and an
// evaluator Grammar holding transform/function pools and op tables.
// Because MoonBit is synchronous, eval and evalSync are the same
// operation; JS's Promise distinction collapses.

///|
/// Top-level expression error carrying a Jexl-style message.
/// Lex, parse, and evaluation errors all surface here so callers
/// handle one error type, like Jexl callers catch one Error.
pub(all) suberror JexlError {
  JexlErr(String)
}

///|
/// A transform/function callback: arguments are pre-evaluated values;
/// for transforms the subject arrives as argument 0, matching Jexl.
pub type Fn = (Array[@ast.Value]) -> @ast.Value raise @evaluator.EvalError

///|
/// The Jexl instance: an expression language engine with an isolated
/// grammar. Ported from Jexl's `Jexl` class.
pub struct Jexl {
  // Element registry, kept sorted by symbol length descending so the
  // lexer's longest-first matching stays correct after add/remove op.
  elements : Array[@grammar.ElementDef]
  grammar : @evaluator.Grammar
}

///|
/// Creates a new Jexl instance with the default grammar.
pub fn new_jexl() -> Jexl {
  {
    elements: @grammar.default_elements(),
    grammar: @evaluator.default_grammar(),
  }
}

///|
/// Inserts an element definition keeping the length-descending sort
/// order the lexer relies on; replaces an existing same-symbol entry.
fn Jexl::upsert_element(self : Jexl, def : @grammar.ElementDef) -> Unit {
  let sym = def.symbol
  let mut idx = 0
  let mut found = false
  while idx < self.elements.length() {
    if self.elements[idx].symbol == sym {
      self.elements[idx] = def
      found = true
      break
    }
    if self.elements[idx].symbol.length() < sym.length() {
      break
    }
    idx += 1
  }
  if !found {
    self.elements.insert(idx, def)
  }
}

///|
/// Upserts a callback in a pool list.
fn upsert_fn(list : Array[(String, Fn)], name : String, f : Fn) -> Unit {
  for i in 0..<list.length() {
    let (n, _) = list[i]
    if n == name {
      list[i] = (name, f)
      return
    }
  }
  list.push((name, f))
}

///|
fn[A] remove_pair(list : Array[(String, A)], name : String) -> Unit {
  let mut i = 0
  while i < list.length() {
    let (n, _) = list[i]
    if n == name {
      ignore(list.remove(i))
      return
    }
    i += 1
  }
}

///|
/// Adds or replaces a transform function. Mirrors `addTransform`.
pub fn Jexl::add_transform(self : Jexl, name : String, f : Fn) -> Unit {
  upsert_fn(self.grammar.transforms, name, f)
}

///|
/// Adds or replaces transforms in batch. Mirrors `addTransforms`.
pub fn Jexl::add_transforms(self : Jexl, map : Array[(String, Fn)]) -> Unit {
  for pair in map {
    let (name, f) = pair
    self.add_transform(name, f)
  }
}

///|
/// Adds or replaces an expression function. Mirrors `addFunction`.
pub fn Jexl::add_function(self : Jexl, name : String, f : Fn) -> Unit {
  upsert_fn(self.grammar.functions, name, f)
}

///|
/// Adds or replaces expression functions in batch. Mirrors `addFunctions`.
pub fn Jexl::add_functions(self : Jexl, map : Array[(String, Fn)]) -> Unit {
  for pair in map {
    let (name, f) = pair
    self.add_function(name, f)
  }
}

///|
/// Retrieves a previously set transform function. Mirrors `getTransform`.
pub fn Jexl::get_transform(self : Jexl, name : String) -> Fn? {
  for pair in self.grammar.transforms {
    let (n, f) = pair
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
/// Retrieves a previously set expression function. Mirrors `getFunction`.
pub fn Jexl::get_function(self : Jexl, name : String) -> Fn? {
  for pair in self.grammar.functions {
    let (n, f) = pair
    if n == name {
      return Some(f)
    }
  }
  None
}

///|
/// Adds a binary operator at the given precedence. Mirrors
/// `addBinaryOp` (eager operand evaluation).
pub fn Jexl::add_binary_op(
  self : Jexl,
  operator : String,
  precedence : Int,
  f : (@ast.Value, @ast.Value) -> @ast.Value,
) -> Unit {
  self.upsert_element(
    @grammar.element_def(operator, @grammar.BinaryOp, precedence),
  )
  // Jexl's addBinaryOp sets `eval`, dropping any evalOnDemand entry.
  remove_pair(self.grammar.on_demand_ops, operator)
  remove_pair(self.grammar.binary_ops, operator)
  self.grammar.binary_ops.push((operator, f))
}

///|
/// Adds a binary operator with manual (on-demand) operand evaluation:
/// the callback receives two lazy operands and decides whether to
/// evaluate each. Mirrors `addBinaryOp` with `manualEval=true`.
pub fn Jexl::add_binary_op_manual(
  self : Jexl,
  operator : String,
  precedence : Int,
  f : (@evaluator.Lazy, @evaluator.Lazy) -> @ast.Value raise @evaluator.EvalError,
) -> Unit {
  self.upsert_element(
    @grammar.element_def(operator, @grammar.BinaryOp, precedence),
  )
  remove_pair(self.grammar.binary_ops, operator)
  remove_pair(self.grammar.on_demand_ops, operator)
  self.grammar.on_demand_ops.push((operator, f))
}

///|
/// Adds a unary operator. Mirrors `addUnaryOp`.
pub fn Jexl::add_unary_op(
  self : Jexl,
  operator : String,
  f : (@ast.Value) -> @ast.Value,
) -> Unit {
  self.upsert_element(@grammar.element_def(operator, @grammar.UnaryOp, 1000000))
  remove_pair(self.grammar.unary_ops, operator)
  self.grammar.unary_ops.push((operator, f))
}

///|
/// Removes a binary or unary operator. Mirrors `removeOp`: the symbol
/// leaves the element registry (so the lexer no longer splits on it)
/// and its eval function is dropped.
pub fn Jexl::remove_op(self : Jexl, operator : String) -> Unit {
  let mut i = 0
  while i < self.elements.length() {
    if self.elements[i].symbol == operator {
      ignore(self.elements.remove(i))
      break
    }
    i += 1
  }
  remove_pair(self.grammar.binary_ops, operator)
  remove_pair(self.grammar.on_demand_ops, operator)
  remove_pair(self.grammar.unary_ops, operator)
}

///|
/// Constructs an Expression object without compiling it.
/// Mirrors `createExpression`.
pub fn Jexl::create_expression(self : Jexl, expr_str : String) -> Expression {
  Expression::{ jexl: self, expr_str, compiled: None }
}

///|
/// Compiles an expression string into an Expression immediately.
/// Mirrors Jexl's `compile`.
pub fn Jexl::compile(
  self : Jexl,
  expr_str : String,
) -> Expression raise JexlError {
  let expr_obj = self.create_expression(expr_str)
  expr_obj.compile()
  expr_obj
}

///|
/// Evaluates an expression string within a context.
/// Mirrors Jexl's `eval`/`evalSync` (identical here — synchronous).
pub fn Jexl::eval(
  self : Jexl,
  expr_str : String,
  context : @ast.Value,
) -> @ast.Value raise JexlError {
  let expr_obj = self.create_expression(expr_str)
  expr_obj.eval(context)
}

///|
/// Tokenizes + parses + evaluates with an empty context.
pub fn Jexl::eval_default(
  self : Jexl,
  expr_str : String,
) -> @ast.Value raise JexlError {
  self.eval(expr_str, @ast.ObjectVal([]))
}
