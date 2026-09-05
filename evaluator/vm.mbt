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
/// A compiled program.
pub struct Program {
  opcodes : Array[Int]
  operands : Array[Int]
  consts : Array[Const]
  max_stack : Int
}

///|
priv struct Compiler {
  opcodes : Array[Int]
  operands : Array[Int]
  consts : Array[Const]
  grammar : Grammar
  // stack-depth simulation for max_stack (filter frames tracked)
  mut cur_depth : Int
  mut max_depth_seen : Int
  filter_depths : Array[Int]
}

///|
/// Compiles a (preferably constant-folded) AST into a Program.
/// Compilation needs the grammar to pre-resolve operators and detect
/// lazy (manual-eval) operators, mirroring expr's compiler.
pub fn compile_program(
  ast : @ast.AstNode,
  grammar : Grammar,
) -> Program raise EvalError {
  let c = {
    opcodes: [],
    operands: [],
    consts: [],
    grammar,
    cur_depth: 0,
    max_depth_seen: 0,
    filter_depths: [],
  }
  c.compile_node(ast)
  {
    opcodes: c.opcodes,
    operands: c.operands,
    consts: c.consts,
    max_stack: c.max_depth_seen + 2,
  }
}

///|
fn Compiler::emit(self : Compiler, op : Int, operand : Int) -> Int {
  self.opcodes.push(op)
  self.operands.push(operand)
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
fn Compiler::compile_node(
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
          let idx = self.const_idx(CVal(@ast.StrVal(node.ident_name)))
          if node.relative {
            ignore(self.emit(OP_LOADREL, idx))
          } else {
            ignore(self.emit(OP_LOADCTX, idx))
          }
          self.track(0, 1)
        }
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
    @ast.ConditionalExpressionNode => {
      match node.cond_test {
        Some(t) => self.compile_node(t)
        None => ()
      }
      let jf = self.emit(OP_JUMPIFFALSE, 0)
      self.track(1, 0)
      match node.consequent {
        Some(c) => self.compile_node(c)
        None => {
          ignore(self.emit(OP_CONST, self.const_idx(CVal(@ast.UndefVal))))
          self.track(0, 1)
        }
      }
      let jend = self.emit(OP_JUMP, 0)
      self.patch(jf, self.opcodes.length())
      match node.alternate {
        Some(a) => self.compile_node(a)
        None => {
          ignore(self.emit(OP_CONST, self.const_idx(CVal(@ast.UndefVal))))
          self.track(0, 1)
        }
      }
      self.patch(jend, self.opcodes.length())
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
            pred_prog = Some(compile_program(a, self.grammar))
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
  match node.left {
    Some(l) => self.compile_node(l)
    None => ()
  }
  match node.right {
    Some(r) => self.compile_node(r)
    None => ()
  }
  match op {
    "&&" => {
      let j = self.emit(OP_ANDJUMP, 0)
      self.track(1, 0)
      self.patch(j, self.opcodes.length())
    }
    "||" => {
      let j = self.emit(OP_ORJUMP, 0)
      self.track(1, 0)
      self.patch(j, self.opcodes.length())
    }
    "??" => {
      let j = self.emit(OP_COALESCE, 0)
      self.track(1, 0)
      self.patch(j, self.opcodes.length())
    }
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
  match node.filter_expr {
    Some(e) => self.compile_node(e)
    None => {
      ignore(self.emit(OP_CONST, self.const_idx(CVal(@ast.UndefVal))))
      self.track(0, 1)
    }
  }
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
  return_pc : Int
  pred_start : Int
}

///|
#warnings("-unused_mut")
priv struct VmState {
  opcodes : Array[Int]
  operands : Array[Int]
  consts : Array[Const]
  mut pc : Int
  stack : Array[@ast.Value]
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
  }
  e.eval(ast)
}

///|
fn VmState::run(self : VmState) -> @ast.Value raise EvalError {
  let n = self.opcodes.length()
  while self.pc < n {
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
          self.push(@ast.ArrayVal([]))
          self.pc = operand
        } else {
          self.frames.push({
            list,
            idx: 0,
            results: [],
            saved_rel: self.rel_context,
            return_pc: self.pc + 1,
            pred_start: 0,
          })
          self.rel_context = list[0]
          self.pc = operand
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
              self.pc = operand
            } else {
              self.push(@ast.ArrayVal(frame.results.copy()))
              self.rel_context = frame.saved_rel
              self.pc = frame.return_pc
              ignore(self.frames.pop())
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
      OP_LAZYBIN =>
        match self.consts[operand] {
          CAst(node) => {
            self.push(self.walk_eval(node))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad ast constant")
        }
      _ => raise EvalError::EvalErr("VM: unknown opcode")
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
