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
pub(all) suberror EngineError {
  EngineErr(String)
}

///|
/// A transform/function callback: arguments are pre-evaluated values;
/// for transforms the subject arrives as argument 0, matching Jexl.
pub type Fn = (Array[@ast.Value]) -> @ast.Value raise @evaluator.EvalError

///|
/// Execution engine selection. Walk is the reference tree-walk
/// interpreter; Vm compiles the (folded) AST to bytecode and runs the
/// stack machine. Both engines share one semantic layer
/// (evaluator/semantics), so they can only differ in dispatch.
pub(all) enum EngineMode {
  Walk
  Vm
}

///|
/// The Jexl instance: an expression language engine with an isolated
/// grammar. Ported from Jexl's `Jexl` class.
pub struct Engine {
  // Element registry, kept sorted by symbol length descending so the
  // lexer's longest-first matching stays correct after add/remove op.
  elements : Array[@grammar.ElementDef]
  grammar : @evaluator.Grammar
  // Resource budgets, mirroring expr's MaxNodes / memory protections.
  // 0 disables a limit.
  mut max_nodes : Int
  mut max_depth : Int
  mut max_steps : Int
  mut engine : EngineMode
  // Expression-defined user-function call depth (userfuncs.mbt):
  // incremented per user-function call on this instance so recursion
  // across any registration batch raises instead of overflowing the
  // host stack.
  mut userfn_depth : Int
  // Resource-gate observability: how often each budget was hit, keyed by
  // reason ("nodes", "nesting", "depth", "steps", "memory",
  // "value_nesting"). Budget *messages* are contract-locked (AGENTS.md),
  // so this is where the outcome of the gate is reported instead.
  budget_stats : Array[(String, Int)]
}

///|
/// Creates a new Jexl instance with the default grammar.
pub fn new() -> Engine {
  let g = @evaluator.default_grammar()
  // Seed the function pool with the expr-style builtin library.
  for pair in @builtin.functions() {
    let (name, f) = pair
    upsert_fn(g.functions, name, f)
  }
  {
    elements: @grammar.default_elements(),
    grammar: g,
    max_nodes: @parser.default_max_nodes(),
    max_depth: @evaluator.default_max_depth(),
    max_steps: @evaluator.default_max_steps(),
    engine: Walk,
    userfn_depth: 0,
    budget_stats: [],
  }
}

///|
/// Sets the resource budgets: expression node (token) limit applied
/// at parse time, and max evaluation depth / steps applied at eval
/// time. 0 disables a limit. Mirrors expr's MaxNodes and memory
/// budget options.
pub fn Engine::set_limits(
  self : Engine,
  max_nodes : Int,
  max_depth : Int,
  max_steps : Int,
) -> Unit {
  self.max_nodes = max_nodes
  self.max_depth = max_depth
  self.max_steps = max_steps
}

///|
/// Drops the instance's cross-call caches (the compiled `matches`
/// patterns). Nothing else is retained between evaluations, so this
/// returns the instance to its initial memory footprint — an embedder
/// fed unbounded dynamic patterns can call it periodically instead of
/// relying on the cache's own capacity bound.
pub fn Engine::clear_caches(self : Engine) -> Unit {
  @evaluator.clear_regex_cache(self.grammar)
}

///|
/// Maps a budget-error message to the counter it belongs to. Returns
/// `None` for ordinary errors (syntax, type, unknown name), which are
/// not resource-gate events. The messages themselves are contract-locked
/// and must not change, so classification is by the documented wording.
fn budget_reason(msg : String) -> String? {
  if msg.contains("expression is too large") {
    Some("nodes")
  } else if msg.contains("expression is too deeply nested") {
    Some("nesting")
  } else if msg.contains("expression is too deep") {
    Some("depth")
  } else if msg.contains("memory budget exceeded") {
    Some("memory")
  } else if msg.contains("value nesting too deep") {
    Some("value_nesting")
  } else if msg.contains("max depth reached") {
    Some("flatten_depth")
  } else {
    None
  }
}

///|
/// Records one resource-gate event. Called from the stage guards below,
/// exactly once per failed evaluation stage.
fn Engine::record_budget_violation(self : Engine, msg : String) -> Unit {
  match budget_reason(msg) {
    None => ()
    Some(reason) => {
      for i in 0..<self.budget_stats.length() {
        let (r, n) = self.budget_stats[i]
        if r == reason {
          self.budget_stats[i] = (r, n + 1)
          return
        }
      }
      self.budget_stats.push((reason, 1))
    }
  }
}

///|
/// Runs one evaluation stage, recording a resource-gate violation before
/// re-raising. The error is turned into a value first so the grammar and
/// the counters are never touched inside a handler (the toolchain rejects
/// cleanup-and-rethrow in `catch`).
fn[T] Engine::guard_budget(
  self : Engine,
  f : () -> T raise EngineError,
) -> T raise EngineError {
  let r : Result[T, String] = try {
    Ok(f())
  } catch {
    EngineError::EngineErr(m) => Err(m)
  }
  match r {
    Ok(v) => v
    Err(m) => {
      self.record_budget_violation(m)
      raise EngineError::EngineErr(m)
    }
  }
}

///|
/// Snapshot of how often each resource budget has been hit on this
/// instance, as `(reason, count)` pairs in first-hit order. This is the
/// gate's monitoring surface: budget messages are fixed strings, so
/// without it a tripped limit is invisible to the embedder. `reason` is
/// one of `nodes`, `nesting`, `depth`, `steps`, `memory`,
/// `value_nesting`, `flatten_depth`.
pub fn Engine::budget_stats(self : Engine) -> Array[(String, Int)] {
  self.budget_stats.copy()
}

///|
/// Resets the resource-gate counters (e.g. after scraping them into
/// metrics). Does not touch the budgets themselves.
pub fn Engine::reset_budget_stats(self : Engine) -> Unit {
  self.budget_stats.clear()
}

///|
/// Selects the execution engine. The Vm mode compiles the AST to
/// bytecode once per Expression and reuses the program; the default
/// Walk mode is the reference tree-walk interpreter. Both engines
/// share one semantic layer, and vm_parity tests assert their
/// equality across the whole corpus.
pub fn Engine::set_engine(self : Engine, mode : EngineMode) -> Unit {
  self.engine = mode
}

///|
/// Inserts an element definition keeping the length-descending sort
/// order the lexer relies on; replaces an existing same-symbol entry.
fn Engine::upsert_element(self : Engine, def : @grammar.ElementDef) -> Unit {
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
pub fn Engine::add_transform(self : Engine, name : String, f : Fn) -> Unit {
  upsert_fn(self.grammar.transforms, name, f)
}

///|
/// Adds or replaces transforms in batch. Mirrors `addTransforms`.
pub fn Engine::add_transforms(self : Engine, map : Array[(String, Fn)]) -> Unit {
  for pair in map {
    let (name, f) = pair
    self.add_transform(name, f)
  }
}

///|
/// Adds or replaces an expression function. Mirrors `addFunction`.
pub fn Engine::add_function(self : Engine, name : String, f : Fn) -> Unit {
  upsert_fn(self.grammar.functions, name, f)
}

///|
/// Adds or replaces expression functions in batch. Mirrors `addFunctions`.
pub fn Engine::add_functions(self : Engine, map : Array[(String, Fn)]) -> Unit {
  for pair in map {
    let (name, f) = pair
    self.add_function(name, f)
  }
}

///|
/// Retrieves a previously set transform function. Mirrors `getTransform`.
pub fn Engine::get_transform(self : Engine, name : String) -> Fn? {
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
pub fn Engine::get_function(self : Engine, name : String) -> Fn? {
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
pub fn Engine::add_binary_op(
  self : Engine,
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
  self.grammar.binary_ops.push(
    (
      operator,
      fn(
        a : @ast.Value,
        b : @ast.Value,
      ) -> @ast.Value raise @evaluator.EvalError {
        f(a, b)
      },
    ),
  )
}

///|
/// Adds a binary operator with manual (on-demand) operand evaluation:
/// the callback receives two lazy operands and decides whether to
/// evaluate each. Mirrors `addBinaryOp` with `manualEval=true`.
pub fn Engine::add_binary_op_manual(
  self : Engine,
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
pub fn Engine::add_unary_op(
  self : Engine,
  operator : String,
  f : (@ast.Value) -> @ast.Value,
) -> Unit {
  self.upsert_element(@grammar.element_def(operator, @grammar.UnaryOp, 1000000))
  remove_pair(self.grammar.unary_ops, operator)
  self.grammar.unary_ops.push(
    (
      operator,
      fn(v : @ast.Value) -> @ast.Value raise @evaluator.EvalError { f(v) },
    ),
  )
}

///|
/// Removes a binary or unary operator. Mirrors `removeOp`: the symbol
/// leaves the element registry (so the lexer no longer splits on it)
/// and its eval function is dropped.
pub fn Engine::remove_op(self : Engine, operator : String) -> Unit {
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
pub fn Engine::create_expression(
  self : Engine,
  expr_str : String,
) -> Expression {
  Expression::{ engine: self, expr_str, compiled: None, program: None }
}

///|
/// Compiles an expression string into an Expression immediately.
/// Mirrors Jexl's `compile`.
pub fn Engine::compile(
  self : Engine,
  expr_str : String,
) -> Expression raise EngineError {
  let expr_obj = self.create_expression(expr_str)
  expr_obj.compile()
  expr_obj
}

///|
/// Evaluates an expression string within a context.
/// Mirrors Jexl's `eval`/`evalSync` (identical here — synchronous).
pub fn Engine::eval(
  self : Engine,
  expr_str : String,
  context : @ast.Value,
) -> @ast.Value raise EngineError {
  let expr_obj = self.create_expression(expr_str)
  expr_obj.eval(context)
}

///|
/// Tokenizes + parses + evaluates with an empty context.
pub fn Engine::eval_default(
  self : Engine,
  expr_str : String,
) -> @ast.Value raise EngineError {
  self.eval(expr_str, @ast.ObjectVal([]))
}
