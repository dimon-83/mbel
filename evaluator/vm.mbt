// SPDX-License-Identifier: Apache-2.0
// mbel — bytecode compiler + stack VM (engine mode "Vm").
//
// Design invariants:
// 1. Single-source semantics: instructions only *schedule*; every
//    semantic decision (arithmetic, coercion, regex, pool lookup,
//    drill-down) goes through the same functions the tree-walk engine
//    uses. The engines can therefore only diverge in dispatch order,
//    never in what an operation computes.
// 2. Operators are PRE-RESOLVED at compile time: eager binary/unary
//    ops become direct function references in the constant pool
//    (CFn/CUFn) — the VM never searches by name. Grammar changes
//    invalidate compiled programs via Expression recompilation.
// 3. Instructions are parallel Int arrays (opcode + operand), the
//    operand stack is pre-allocated at compile-time max depth and
//    driven by an sp pointer, and relative filters compile to native
//    loop frames (OP_FILTERBEGIN/END) or static index ops — no
//    per-element Evaluator allocation on the hot path.
// 4. The step budget is charged at ALLOCATION points only (array/
//    object construction, filter size), mirroring expr's memGrow.

///|
/// Compile-time constant pool entries.
pub(all) enum Const {
  CVal(@ast.Value)
  CAst(@ast.AstNode)
  CRaise(String) // unconditional runtime error (reached branch)
  CKeys(Array[String])
  CFunc(String, String, Int) // name, pool, argc
  CFn((@ast.Value, @ast.Value) -> @ast.Value raise EvalError)
  CUFn((@ast.Value) -> @ast.Value raise EvalError)
  CAgg(String, Int, Program?) // name, non-predicate argc, predicate program
}

///|
/// Opcodes (parallel-array encoding: opcode + Int operand).
const OP_CONST = 0

///|
const OP_LOADCTX = 1

///|
const OP_LOADREL = 2

///|
const OP_FETCH = 3

///|
const OP_CALLBINFN = 4

///|
const OP_CALLUNFN = 5

///|
const OP_MATCHES = 6

///|
const OP_ANDJUMP = 7

///|
const OP_ORJUMP = 8

///|
const OP_COALESCE = 9

///|
const OP_JUMP = 10

///|
const OP_JUMPIFFALSE = 11

///|
const OP_ARRAY = 12

///|
const OP_OBJECT = 13

///|
const OP_CALLFUNC = 14

///|
const OP_FILTERBEGIN = 15

///|
const OP_FILTEREND = 16

///|
const OP_FILTERSTATIC = 17

///|
const OP_LAZYBIN = 18

///|
const OP_LOADSLOT = 19

///|
const OP_CALLAGG = 20

///|
const OP_SLICE = 21

///|
const OP_LOADLOCAL = 22

///|
const OP_ADDLOCAL = 23

///|
const OP_POPLOCAL = 24

///|
const OP_ENV = 25

///|
/// A compiled program.
pub struct Program {
  opcodes : Array[Int]
  operands : Array[Int]
  consts : Array[Const]
  max_stack : Int
  // Per-instruction source AST depth (tree depth of the node the
  // instruction belongs to) plus its maximum — lets the Vm enforce
  // the same max_depth budget as the tree-walk engine.
  depths : Array[Int]
  max_node_depth : Int
}

///|
priv struct Compiler {
  opcodes : Array[Int]
  operands : Array[Int]
  depths : Array[Int]
  consts : Array[Const]
  grammar : Grammar
  // stack-depth simulation for max_stack (filter frames tracked)
  mut cur_depth : Int
  mut max_depth_seen : Int
  filter_depths : Array[Int]
  // statically known let-bindings in scope (name per local slot); the
  // mirror of the runtime locals array order
  local_names : Array[String]
  // source AST depth of the node currently being compiled (for the
  // per-instruction depth budget); max over all emitted instructions
  mut node_depth : Int
  mut max_node_depth : Int
  // relative-filter predicates compile against a rebased depth (the
  // walk engine evaluates them on a fresh per-element evaluator)
  mut pred_depth_rebase : Int
}

///|
/// Compiles a (preferably constant-folded) AST into a Program.
/// Compilation needs the grammar to pre-resolve operators and detect
/// lazy (manual-eval) operators, mirroring expr's compiler.
pub fn compile_program(
  ast : @ast.AstNode,
  grammar : Grammar,
) -> Program raise EvalError {
  compile_program_with_locals(ast, grammar, [])
}

///|
/// Like compile_program, but starting with `outer` let-bindings already
/// in scope (used for aggregate predicate sub-programs, which may read
/// variables bound by the enclosing sequence).
pub fn compile_program_with_locals(
  ast : @ast.AstNode,
  grammar : Grammar,
  outer : Array[String],
) -> Program raise EvalError {
  let c = {
    opcodes: [],
    operands: [],
    depths: [],
    consts: [],
    grammar,
    cur_depth: 0,
    max_depth_seen: 0,
    filter_depths: [],
    local_names: outer.copy(),
    node_depth: 0,
    max_node_depth: 0,
    pred_depth_rebase: 0,
  }
  c.compile_node(ast)
  {
    opcodes: c.opcodes,
    operands: c.operands,
    consts: c.consts,
    max_stack: c.max_depth_seen + 2,
    depths: c.depths,
    max_node_depth: c.max_node_depth,
  }
}

///|
fn Compiler::emit(self : Compiler, op : Int, operand : Int) -> Int {
  self.opcodes.push(op)
  self.operands.push(operand)
  // source-AST depth of the node this instruction belongs to (rebased
  // while compiling relative-filter predicates — see compile_filter)
  let d = self.node_depth - self.pred_depth_rebase
  self.depths.push(d)
  if d > self.max_node_depth {
    self.max_node_depth = d
  }
  self.opcodes.length() - 1
}

///|
fn Compiler::patch(self : Compiler, addr : Int, operand : Int) -> Unit {
  self.operands[addr] = operand
}

///|
fn Compiler::const_idx(self : Compiler, c : Const) -> Int {
  match c {
    CVal(v) =>
      for i in 0..<self.consts.length() {
        match self.consts[i] {
          CVal(v2) => if @ast.value_equal(v, v2) { return i }
          _ => ()
        }
      }
    _ => ()
  }
  self.consts.push(c)
  self.consts.length() - 1
}

///|
/// Tracks stack depth: `pops` then `pushes`, recording the peak.
fn Compiler::track(self : Compiler, pops : Int, pushes : Int) -> Unit {
  self.cur_depth -= pops
  self.cur_depth += pushes
  if self.cur_depth > self.max_depth_seen {
    self.max_depth_seen = self.cur_depth
  }
}

///|

///|
/// Compiles a node, tracking its source-AST depth for the per-
/// instruction depth budget. Compilation failures abort the whole
/// compile, so a raise needs no depth restore.
fn Compiler::compile_node(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  self.node_depth += 1
  self.compile_node_inner(node)
  self.node_depth -= 1
}

///|
fn Compiler::compile_node_inner(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  match node.node_type {
    @ast.LiteralNode => {
      let idx = self.const_idx(CVal(node.value))
      ignore(self.emit(OP_CONST, idx))
      self.track(0, 1)
    }
    @ast.IdentifierNode =>
      match node.from {
        Some(from) => {
          self.compile_node(from)
          let idx = self.const_idx(CVal(@ast.StrVal(node.ident_name)))
          ignore(self.emit(OP_FETCH, idx))
          self.track(1, 1)
        }
        None => {
          // `$env` pushes the whole context; let-bound names resolve to
          // local slots (innermost wins); otherwise context/rel lookup.
          if !node.relative {
            if node.ident_name == "$env" {
              ignore(self.emit(OP_ENV, 0))
              self.track(0, 1)
              return
            }
            let slot = find_local_slot(self.local_names, node.ident_name)
            if slot >= 0 {
              ignore(self.emit(OP_LOADLOCAL, slot))
              self.track(0, 1)
              return
            }
          }
          let idx = self.const_idx(CVal(@ast.StrVal(node.ident_name)))
          if node.relative {
            ignore(self.emit(OP_LOADREL, idx))
          } else {
            ignore(self.emit(OP_LOADCTX, idx))
          }
          self.track(0, 1)
        }
      }
    @ast.SequenceNode => self.compile_sequence(node)
    @ast.VariableDeclaratorNode =>
      raise EvalError::EvalErr("variable declarator outside a sequence")
    @ast.SliceNode => {
      // subject; [from]; [to]; OP_SLICE(flags) with flag bits 1=from, 2=to
      match node.subject {
        Some(s) => self.compile_node(s)
        None => ()
      }
      let mut flags = 0
      let mut pushed = 1
      match node.slice_from {
        Some(f) => {
          self.compile_node(f)
          flags = flags | 1
          pushed += 1
        }
        None => ()
      }
      match node.slice_to {
        Some(t) => {
          self.compile_node(t)
          flags = flags | 2
          pushed += 1
        }
        None => ()
      }
      ignore(self.emit(OP_SLICE, flags))
      self.track(pushed, 1)
    }
    @ast.BinaryExpressionNode => self.compile_binary(node)
    @ast.UnaryExpressionNode => {
      match node.right {
        Some(r) => self.compile_node(r)
        None => ()
      }
      match find_un(self.grammar.unary_ops, node.operator) {
        Some(f) => {
          ignore(self.emit(OP_CALLUNFN, self.const_idx(CUFn(f))))
          self.track(1, 1)
        }
        None => {
          // Unknown op: deferred to runtime name lookup via a lazy
          // callback (never happens for well-formed programs).
          let idx = self.const_idx(CAst(node))
          ignore(self.emit(OP_LAZYBIN, idx))
          self.track(0, 1)
        }
      }
    }
    @ast.ConditionalExpressionNode =>
      match node.consequent {
        // Elvis form `a ?: b`: a truthy test IS the result, so jump
        // over the alternate keeping the test value (OP_ORJUMP path).
        None => {
          match node.cond_test {
            Some(t) => self.compile_node(t)
            None => ()
          }
          let j = self.emit(OP_ORJUMP, 0)
          self.track(1, 0)
          self.compile_alt_or_raise(node)
          self.patch(j, self.opcodes.length())
        }
        Some(_) => {
          match node.cond_test {
            Some(t) => self.compile_node(t)
            None => ()
          }
          let jf = self.emit(OP_JUMPIFFALSE, 0)
          self.track(1, 0)
          match node.consequent {
            Some(c) => self.compile_node(c)
            None => () // unreachable: guarded by the outer match
          }
          let jend = self.emit(OP_JUMP, 0)
          self.patch(jf, self.opcodes.length())
          self.compile_alt_or_raise(node)
          self.patch(jend, self.opcodes.length())
        }
      }
    @ast.ArrayLiteralNode => {
      let n = node.array_value.length()
      for x in node.array_value {
        self.compile_node(x)
      }
      ignore(self.emit(OP_ARRAY, n))
      self.track(n, 1)
    }
    @ast.ObjectLiteralNode => {
      let keys : Array[String] = []
      for kv in node.obj_value {
        let (k, v) = kv
        keys.push(k)
        self.compile_node(v)
      }
      let idx = self.const_idx(CKeys(keys))
      ignore(self.emit(OP_OBJECT, idx))
      self.track(keys.length(), 1)
    }
    @ast.FilterExpressionNode => self.compile_filter(node)
    @ast.FunctionCallNode => {
      let argc = node.args.length()
      // Aggregate calls with a predicate compile to OP_CALLAGG with
      // the predicate compiled into a reusable sub-program (typed
      // slots: #, #index, #acc).
      if node.pool == "functions" && @grammar.is_aggregate(node.func_name) {
        let has_pred = argc > 1 && node.args[1].is_pred
        let mut non_pred = 0
        let mut pred_prog : Program? = None
        for i in 0..<argc {
          let a = node.args[i]
          if i == 1 && has_pred {
            pred_prog = Some(
              compile_program_with_locals(a, self.grammar, self.local_names),
            )
          } else {
            self.compile_node(a)
            non_pred += 1
          }
        }
        let idx = self.const_idx(CAgg(node.func_name, non_pred, pred_prog))
        ignore(self.emit(OP_CALLAGG, idx))
        self.track(argc, 1)
        return
      }
      for a in node.args {
        self.compile_node(a)
      }
      let idx = self.const_idx(CFunc(node.func_name, node.pool, argc))
      ignore(self.emit(OP_CALLFUNC, idx))
      self.track(argc, 1)
    }
    @ast.PointerNode => {
      let slot = match node.ident_name {
        "#index" => 1
        "#acc" => 2
        _ => 0
      }
      ignore(self.emit(OP_LOADSLOT, slot))
      self.track(0, 1)
    }
  }
}

///|
fn Compiler::compile_binary(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  let op = node.operator
  // Lazy (manual-eval) operators need unevaluated operands: callback.
  if find_lazy(self.grammar.on_demand_ops, op) is Some(_) &&
    op != "&&" &&
    op != "||" &&
    op != "??" {
    let idx = self.const_idx(CAst(node))
    ignore(self.emit(OP_LAZYBIN, idx))
    self.track(0, 1)
    return
  }
  // &&/||/?? are lazy: the jump must sit BETWEEN the operands so the
  // right side is genuinely skipped when short-circuited (the dispatch
  // arms pop the left value in the fall-through path and keep it in
  // the jump path).
  if op == "&&" || op == "||" || op == "??" {
    match node.left {
      Some(l) => self.compile_node(l)
      None => ()
    }
    let j = match op {
      "&&" => self.emit(OP_ANDJUMP, 0)
      "||" => self.emit(OP_ORJUMP, 0)
      _ => self.emit(OP_COALESCE, 0)
    }
    self.track(1, 0)
    match node.right {
      Some(r) => self.compile_node(r)
      None => ()
    }
    self.patch(j, self.opcodes.length())
    return
  }
  match node.left {
    Some(l) => self.compile_node(l)
    None => ()
  }
  match node.right {
    Some(r) => self.compile_node(r)
    None => ()
  }
  match op {
    "matches" => {
      ignore(self.emit(OP_MATCHES, 0))
      self.track(2, 1)
    }
    _ =>
      match find_bin(self.grammar.binary_ops, op) {
        Some(f) => {
          ignore(self.emit(OP_CALLBINFN, self.const_idx(CFn(f))))
          self.track(2, 1)
        }
        None => {
          let idx = self.const_idx(CAst(node))
          ignore(self.emit(OP_LAZYBIN, idx))
          self.track(0, 1)
        }
      }
  }
}

///|
/// Compiles a conditional's alternate, or — when the parser produced a
/// conditional without one — an unconditional raise matching the
/// tree-walk engine's error. The raise only fires when the missing
/// branch is actually reached.
fn Compiler::compile_alt_or_raise(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  match node.alternate {
    Some(a) => self.compile_node(a)
    None => {
      let idx = self.const_idx(
        CRaise("Conditional expression has no alternate"),
      )
      ignore(self.emit(OP_LAZYBIN, idx))
    }
  }
}

///|
/// Innermost-first index of a name in the compile-time local table, or
/// -1 when not bound.
fn find_local_slot(names : Array[String], name : String) -> Int {
  let mut i = names.length() - 1
  while i >= 0 {
    if names[i] == name {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// Compiles a sequence `a; b; c`: variable declarators bind a new
/// local slot (OP_ADDLOCAL) that subsequent items resolve statically;
/// the bindings are popped (OP_POPLOCAL) at the end of the sequence.
fn Compiler::compile_sequence(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  let mark = self.local_names.length()
  let mut binds = 0
  for item in node.args {
    if item.node_type is @ast.VariableDeclaratorNode {
      self.compile_node(item.args[0])
      let idx = self.const_idx(CVal(@ast.StrVal(item.ident_name)))
      ignore(self.emit(OP_ADDLOCAL, idx))
      self.track(1, 0)
      self.local_names.push(item.ident_name)
      binds += 1
    } else {
      self.compile_node(item)
    }
  }
  if binds > 0 {
    ignore(self.emit(OP_POPLOCAL, binds))
    while self.local_names.length() > mark {
      ignore(self.local_names.pop())
    }
  }
}

///|
/// Compiles a FilterExpression:
///   relative -> subject; FILTERBEGIN(pred_start); <predicate>;
///   FILTEREND(pred_start)  — a native loop over the subject elements
///   with the rel-context slot swapped per element (no per-element
///   evaluator allocation).
///   static  -> subject; <expr>; FILTERSTATIC.
fn Compiler::compile_filter(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  match node.subject {
    Some(sub) => self.compile_node(sub)
    None => ()
  }
  if !node.filter_relative {
    match node.filter_expr {
      Some(e) => self.compile_node(e)
      None => ignore(self.emit(OP_CONST, self.const_idx(CVal(@ast.UndefVal))))
    }
    ignore(self.emit(OP_FILTERSTATIC, 0))
    self.track(2, 1)
    return
  }
  let fb = self.emit(OP_FILTERBEGIN, 0)
  self.track(1, 0)
  // loop body runs with the predicate result pushed per iteration
  self.filter_depths.push(self.cur_depth)
  let pred_start = self.opcodes.length()
  // The walk engine evaluates a relative-filter predicate on a fresh
  // per-element evaluator (depth starts at 1); rebase the depth so the
  // per-instruction budget check matches that accounting. Nested
  // relative filters rebase again from their own (absolute) depth.
  let saved_rebase = self.pred_depth_rebase
  self.pred_depth_rebase = self.node_depth
  match node.filter_expr {
    Some(e) => self.compile_node(e)
    None => {
      ignore(self.emit(OP_CONST, self.const_idx(CVal(@ast.UndefVal))))
      self.track(0, 1)
    }
  }
  self.pred_depth_rebase = saved_rebase
  ignore(self.emit(OP_FILTEREND, pred_start))
  self.cur_depth = self.filter_depths.pop().unwrap_or(0) + 1
  if self.cur_depth > self.max_depth_seen {
    self.max_depth_seen = self.cur_depth
  }
  self.patch(fb, self.opcodes.length())
}

///|
/// Loop frame for relative filters.
priv struct LoopFrame {
  list : Array[@ast.Value]
  mut idx : Int
  results : Array[@ast.Value]
  saved_rel : @ast.Value
}

///|
#warnings("-unused_mut")
priv struct VmState {
  mut opcodes : Array[Int]
  mut operands : Array[Int]
  mut consts : Array[Const]
  mut pc : Int
  mut stack : Array[@ast.Value]
  mut sp : Int
  frames : Array[LoopFrame]
  grammar : Grammar
  context : @ast.Value
  mut rel_context : @ast.Value
  budget : BudgetCell
  max_steps : Int
  max_depth : Int
  mut slot_elem : @ast.Value
  mut slot_idx : Int
  mut slot_acc : @ast.Value
  // lexical let-bindings (innermost last); names kept so tree-walk
  // callbacks (LAZYBIN) can resolve them by name
  mut locals : Array[(String, @ast.Value)]
  // per-instruction source-AST depths + whether any instruction can
  // exceed max_depth (precomputed so the default budget never checks)
  mut depths : Array[Int]
  mut depth_check : Bool
}

///|
/// Runs a compiled program against a context. The VM borrows the
/// grammar's semantic tables and shares the budget cell with any
/// tree-walk callbacks it spawns.
pub fn run_program(
  program : Program,
  grammar : Grammar,
  context : @ast.Value,
  max_depth : Int,
  max_steps : Int,
) -> @ast.Value raise EvalError {
  let vm = {
    opcodes: program.opcodes,
    operands: program.operands,
    consts: program.consts,
    pc: 0,
    stack: Array::make(program.max_stack, @ast.UndefVal),
    sp: 0,
    frames: [],
    grammar,
    context,
    rel_context: context,
    budget: { steps: 0 },
    max_steps,
    max_depth,
    slot_elem: @ast.UndefVal,
    slot_idx: 0,
    slot_acc: @ast.UndefVal,
    locals: [],
    depths: program.depths,
    depth_check: max_depth > 0 && program.max_node_depth > max_depth,
  }
  vm.run()
}

///|
fn VmState::charge(self : VmState, n : Int) -> Unit raise EvalError {
  if self.max_steps > 0 {
    self.budget.steps = self.budget.steps + n
    if self.budget.steps > self.max_steps {
      raise EvalError::EvalErr("memory budget exceeded")
    }
  }
}

///|
fn VmState::push(self : VmState, v : @ast.Value) -> Unit {
  self.stack[self.sp] = v
  self.sp += 1
}

///|
fn VmState::pop(self : VmState) -> @ast.Value raise EvalError {
  if self.sp <= 0 {
    raise EvalError::EvalErr("VM stack underflow")
  }
  self.sp -= 1
  self.stack[self.sp]
}

///|
fn VmState::popn(self : VmState, n : Int) -> Array[@ast.Value] raise EvalError {
  let out : Array[@ast.Value] = []
  let mut i = 0
  while i < n {
    out.push(self.pop())
    i += 1
  }
  out.rev()
}

///|
/// Callback: run an AST subtree on the tree-walk engine with this
/// VM's shared budget and contexts (manual-eval operators only).
fn VmState::walk_eval(
  self : VmState,
  ast : @ast.AstNode,
) -> @ast.Value raise EvalError {
  let e = {
    grammar: self.grammar,
    context: self.context,
    rel_context: self.rel_context,
    depth: 0,
    max_depth: self.max_depth,
    budget: self.budget,
    max_steps: self.max_steps,
    slot_elem: self.slot_elem,
    slot_idx: self.slot_idx,
    slot_acc: self.slot_acc,
    locals: self.locals.copy(),
  }
  e.eval(ast)
}

///|
fn VmState::run(self : VmState) -> @ast.Value raise EvalError {
  let n = self.opcodes.length()
  while self.pc < n {
    // Eval-depth budget (same message and accounting as the tree-walk
    // engine: an executed node deeper than max_depth is rejected).
    if self.depth_check && self.depths[self.pc] > self.max_depth {
      raise EvalError::EvalErr(
        "expression is too deep (more than " +
        self.max_depth.to_string() +
        " levels)",
      )
    }
    let op = self.opcodes[self.pc]
    let operand = self.operands[self.pc]
    match op {
      OP_CONST => {
        match self.consts[operand] {
          CVal(v) => self.push(v)
          _ => raise EvalError::EvalErr("VM: bad constant")
        }
        self.pc += 1
      }
      OP_LOADCTX => {
        match self.consts[operand] {
          CVal(@ast.StrVal(key)) => self.push(key_of_value(self.context, key))
          _ => raise EvalError::EvalErr("VM: bad name constant")
        }
        self.pc += 1
      }
      OP_LOADREL => {
        match self.consts[operand] {
          CVal(@ast.StrVal(key)) =>
            self.push(key_of_value(self.rel_context, key))
          _ => raise EvalError::EvalErr("VM: bad name constant")
        }
        self.pc += 1
      }
      OP_FETCH => {
        let from = self.pop()
        match self.consts[operand] {
          CVal(@ast.StrVal(name)) => self.push(fetch_from(from, name))
          _ => raise EvalError::EvalErr("VM: bad name constant")
        }
        self.pc += 1
      }
      OP_CALLBINFN => {
        let r = self.pop()
        let l = self.pop()
        match self.consts[operand] {
          CFn(f) => self.push(f(l, r))
          _ => raise EvalError::EvalErr("VM: bad binary fn constant")
        }
        self.pc += 1
      }
      OP_CALLUNFN => {
        let v = self.pop()
        match self.consts[operand] {
          CUFn(f) => self.push(f(v))
          _ => raise EvalError::EvalErr("VM: bad unary fn constant")
        }
        self.pc += 1
      }
      OP_MATCHES => {
        let pattern = self.pop()
        let s = self.pop()
        let p = match pattern {
          @ast.StrVal(p) => p
          _ => raise EvalError::EvalErr("matches: pattern must be a string")
        }
        self.push(
          @ast.BoolVal(grammar_regex_match(self.grammar, to_string(s), p)),
        )
        self.pc += 1
      }
      OP_ANDJUMP => {
        let v = self.stack[self.sp - 1]
        if truthy(v) {
          self.sp -= 1
          self.pc += 1
        } else {
          self.pc = operand
        }
      }
      OP_ORJUMP => {
        let v = self.stack[self.sp - 1]
        if truthy(v) {
          self.pc = operand
        } else {
          self.sp -= 1
          self.pc += 1
        }
      }
      OP_COALESCE => {
        let v = self.stack[self.sp - 1]
        match v {
          @ast.NullVal | @ast.UndefVal => {
            self.sp -= 1
            self.pc += 1
          }
          _ => self.pc = operand
        }
      }
      OP_JUMP => self.pc = operand
      OP_JUMPIFFALSE => {
        let v = self.pop()
        if truthy(v) {
          self.pc += 1
        } else {
          self.pc = operand
        }
      }
      OP_ARRAY => {
        let items = self.popn(operand)
        self.charge(1 + operand)
        self.push(@ast.ArrayVal(items))
        self.pc += 1
      }
      OP_OBJECT =>
        match self.consts[operand] {
          CKeys(keys) => {
            let vals = self.popn(keys.length())
            self.charge(1 + keys.length())
            let pairs : Array[(String, @ast.Value)] = []
            for i in 0..<keys.length() {
              pairs.push((keys[i], vals[i]))
            }
            self.push(@ast.ObjectVal(pairs))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad keys constant")
        }
      OP_CALLFUNC =>
        match self.consts[operand] {
          CFunc(name, pool, argc) => {
            let args = self.popn(argc)
            self.push(call_pool_function(self.grammar, pool, name, args))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad function constant")
        }
      OP_LOADSLOT => {
        let v = match operand {
          1 => @ast.NumVal(self.slot_idx.to_double())
          2 => self.slot_acc
          _ => self.slot_elem
        }
        self.push(v)
        self.pc += 1
      }
      OP_FILTERBEGIN => {
        let subject = self.pop()
        let list : Array[@ast.Value] = match subject {
          @ast.ArrayVal(xs) => xs
          @ast.UndefVal => []
          other => [other]
        }
        // Allocation grows with the subject size (expr memGrow).
        self.charge(list.length())
        if list.length() == 0 {
          // Empty subject: result is the empty array; skip the whole
          // predicate block (operand = end of the filter construct).
          self.push(@ast.ArrayVal([]))
          self.pc = operand
        } else {
          // Non-empty: push a frame and fall through into the
          // predicate (pc += 1 lands on pred_start), which runs with
          // the rel-context slot set to the first element.
          self.frames.push({
            list,
            idx: 0,
            results: [],
            saved_rel: self.rel_context,
          })
          self.rel_context = list[0]
          self.pc += 1
        }
      }
      OP_FILTEREND => {
        let pred = self.pop()
        match self.frames[self.frames.length() - 1] {
          frame => {
            if truthy(pred) {
              frame.results.push(frame.list[frame.idx])
            }
            frame.idx += 1
            if frame.idx < frame.list.length() {
              self.rel_context = frame.list[frame.idx]
              // Loop back to the predicate start.
              self.pc = operand
            } else {
              self.push(@ast.ArrayVal(frame.results.copy()))
              self.rel_context = frame.saved_rel
              ignore(self.frames.pop())
              // Fall through past FILTEREND: pc is the end of the
              // filter construct.
              self.pc += 1
            }
          }
        }
      }
      OP_FILTERSTATIC => {
        let res = self.pop()
        let subject = self.pop()
        match res {
          @ast.BoolVal(b) => self.push(if b { subject } else { @ast.UndefVal })
          _ => self.push(index_value(subject, res))
        }
        self.pc += 1
      }
      OP_CALLAGG =>
        match self.consts[operand] {
          CAgg(name, argc, pred_prog) => {
            let values = self.popn(argc)
            let list : Array[@ast.Value] = match values.get(0) {
              Some(@ast.ArrayVal(xs)) => xs
              Some(@ast.UndefVal) | None => []
              Some(_) =>
                raise EvalError::EvalErr(
                  name + ": first argument must be an array",
                )
            }
            let extra = values[1:].to_array()
            let has_pred = pred_prog is Some(_)
            // Reuse ONE sub-VM across elements (typed slots); it
            // inherits a copy of the enclosing lexical bindings so
            // predicates can read outer let-variables.
            let blank = {
              opcodes: [],
              operands: [],
              consts: [],
              pc: 0,
              stack: Array::make(2, @ast.UndefVal),
              sp: 0,
              frames: [],
              grammar: self.grammar,
              context: self.context,
              rel_context: self.rel_context,
              budget: self.budget,
              max_steps: self.max_steps,
              max_depth: self.max_depth,
              slot_elem: @ast.UndefVal,
              slot_idx: 0,
              slot_acc: @ast.UndefVal,
              locals: self.locals.copy(),
              depths: [],
              depth_check: false,
            }
            let sub = match pred_prog {
              Some(prog) => {
                blank.opcodes = prog.opcodes
                blank.operands = prog.operands
                blank.consts = prog.consts
                blank.stack = Array::make(prog.max_stack, @ast.UndefVal)
                blank.depths = prog.depths
                blank.depth_check = self.max_depth > 0 &&
                  prog.max_node_depth > self.max_depth
                blank
              }
              None => blank
            }
            let runner : PredRunner = fn(i, elem, acc) {
              sub.pc = 0
              sub.sp = 0
              sub.rel_context = elem
              sub.slot_elem = elem
              sub.slot_idx = i
              sub.slot_acc = acc
              sub.run()
            }
            self.push(aggregate_call(name, list, has_pred, extra, runner))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad aggregate constant")
        }
      OP_SLICE => {
        let has_to = (operand & 2) != 0
        let has_from = (operand & 1) != 0
        let to_v = if has_to { Some(self.pop()) } else { None }
        let from_v = if has_from { Some(self.pop()) } else { None }
        let subject = self.pop()
        let result = slice_value(subject, from_v, to_v)
        match result {
          @ast.ArrayVal(xs) => self.charge(xs.length())
          _ => ()
        }
        self.push(result)
        self.pc += 1
      }
      OP_LOADLOCAL => {
        self.push(self.locals[operand].1)
        self.pc += 1
      }
      OP_ADDLOCAL => {
        let v = self.pop()
        match self.consts[operand] {
          CVal(@ast.StrVal(name)) => self.locals.push((name, v))
          _ => raise EvalError::EvalErr("VM: bad local name constant")
        }
        self.pc += 1
      }
      OP_POPLOCAL => {
        let mut k = operand
        while k > 0 {
          ignore(self.locals.pop())
          k -= 1
        }
        self.pc += 1
      }
      OP_ENV => {
        self.push(self.context)
        self.pc += 1
      }
      OP_LAZYBIN =>
        match self.consts[operand] {
          CAst(node) => {
            self.push(self.walk_eval(node))
            self.pc += 1
          }
          CRaise(msg) => raise EvalError::EvalErr(msg)
          _ => raise EvalError::EvalErr("VM: bad ast constant")
        }
      _ =>
        raise EvalError::EvalErr(
          "VM: unknown opcode op=" + operand.to_string() + "/" + op.to_string(),
        )
    }
  }
  match self.sp > 0 {
    true => {
      self.sp -= 1
      self.stack[self.sp]
    }
    false => @ast.UndefVal
  }
}

///|
/// Disassembles a compiled program into readable text, one instruction
/// per line: `idx NAME operand  ; note`. Constants referenced by an
/// operand are decoded where possible (strings, call/aggregate names,
/// jump targets); compiled function references print as `<fn>`.
pub fn disassemble(program : Program) -> String {
  let names = [
    "CONST", "LOADCTX", "LOADREL", "FETCH", "CALLBINFN", "CALLUNFN", "MATCHES", "ANDJUMP",
    "ORJUMP", "COALESCE", "JUMP", "JUMPIFFALSE", "ARRAY", "OBJECT", "CALLFUNC", "FILTERBEGIN",
    "FILTEREND", "FILTERSTATIC", "LAZYBIN", "LOADSLOT", "CALLAGG", "SLICE", "LOADLOCAL",
    "ADDLOCAL", "POPLOCAL", "ENV",
  ]
  let jumps = [7, 8, 9, 10, 11, 15, 16] // operand is a pc target
  let out = StringBuilder::new()
  for i in 0..<program.opcodes.length() {
    let op = program.opcodes[i]
    let operand = program.operands[i]
    let name = if op >= 0 && op < names.length() {
      names[op]
    } else {
      "OP?" + op.to_string()
    }
    out.write_string(i.to_string())
    out.write_string("  ")
    out.write_string(name)
    if op != 25 { // ENV has no operand
      out.write_string(" ")
      out.write_string(operand.to_string())
    }
    let note = disasm_note(program, op, operand, jumps)
    if note != "" {
      out.write_string("  ; ")
      out.write_string(note)
    }
    out.write_string("\n")
  }
  out.to_string()
}

///|
fn disasm_note(
  program : Program,
  op : Int,
  operand : Int,
  jumps : Array[Int],
) -> String {
  if contains_int(jumps, op) {
    return "-> " + operand.to_string()
  }
  if operand < 0 || operand >= program.consts.length() {
    return ""
  }
  match (op, program.consts[operand]) {
    // LOADCTX/LOADREL/FETCH/ADDLOCAL carry a name constant
    (1, CVal(@ast.StrVal(s)))
    | (2, CVal(@ast.StrVal(s)))
    | (3, CVal(@ast.StrVal(s)))
    | (23, CVal(@ast.StrVal(s))) => "\"" + s + "\""
    (4, _) | (5, _) => "<fn>" // CALLBINFN/CALLUNFN
    (0, CVal(v)) => to_string(v) // CONST literal
    (13, CKeys(keys)) => {
      let b = StringBuilder::new()
      for k in keys {
        b.write_string(k)
        b.write_string(",")
      }
      b.to_string()
    }
    (14, CFunc(n, p, argc)) => n + "[" + p + "] argc=" + argc.to_string()
    (20, CAgg(n, argc, pred)) =>
      n +
      " argc=" +
      argc.to_string() +
      (if pred is Some(_) { " pred" } else { "" })
    (18, CRaise(msg)) => "raise: " + msg
    (_, _) => ""
  }
}

///|
fn contains_int(xs : Array[Int], x : Int) -> Bool {
  for v in xs {
    if v == x {
      return true
    }
  }
  false
}
