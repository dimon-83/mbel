// SPDX-License-Identifier: Apache-2.0
// mbel — bytecode compiler + stack VM (engine mode "Vm").
//
// Design invariants:
// 1. Single-source semantics: instructions only *schedule*; every
//    semantic decision (arithmetic, coercion, regex, pool lookup,
//    drill-down) goes through the same functions the tree-walk engine
//    uses (apply_binary_op, call_pool_function, fetch_from, ...).
//    The engines can therefore only diverge in dispatch order, never
//    in what an operation computes.
// 2. FilterExpression and lazy (manual-eval) operators are compiled
//    to callback instructions that run the corresponding AST subtree
//    on the tree-walk engine with a shared budget — correct first,
//    instruction-encoded in a later revision.
// 3. The step budget is charged per instruction, and callback paths
//    charge the same shared BudgetCell, so budgets behave equivalently
//    on both engines.

///|
/// Compile-time constant pool entries.
pub(all) enum Const {
  CVal(@ast.Value)
  CAst(@ast.AstNode)
  CKeys(Array[String])
  CFunc(String, String, Int) // name, pool, argc
}

///|
/// The instruction set (16 opcodes).
pub(all) enum Instr {
  OpConst(Int) // push consts[i]
  OpLoadCtx(String) // push context[key]
  OpLoadRel(String) // push rel_context[key]
  OpFetch(String) // pop from-value, push from[name]
  OpBinary(String) // pop r, l; push apply_binary_op(op, l, r)
  OpMatches // pop pattern, s; push regex match
  OpAndJump(Int) // peek; falsy -> jump (keep left); else pop, fall through
  OpOrJump(Int) // peek; truthy -> jump (keep left); else pop, fall through
  OpCoalesceJump(Int) // peek; non-nil -> jump (keep left); else pop
  OpJump(Int)
  OpJumpIfFalse(Int) // pop; falsy -> jump
  OpUnary(String) // pop; push unary op eval
  OpArray(Int) // pop n, build array
  OpObject(Int) // consts[i] = keys; pop n values, build object
  OpCallFunc(Int) // consts[i] = CFunc; pop argc args, push result
  OpFilter(Int) // consts[i] = CAst; tree-walk callback, push result
  OpLazyBinary(Int) // consts[i] = CAst(binary node); lazy-op callback
}

///|
/// A compiled program: instruction array + constant pool.
pub struct Program {
  instrs : Array[Instr]
  consts : Array[Const]
}

///|
priv struct Compiler {
  instrs : Array[Instr]
  consts : Array[Const]
  grammar : Grammar
}

///|
/// Compiles a (preferably constant-folded) AST into a Program.
/// Compilation needs the grammar to detect lazy (manual-eval)
/// operators at compile time, mirroring how expr's compiler consults
/// evalOnDemand.
pub fn compile_program(
  ast : @ast.AstNode,
  grammar : Grammar,
) -> Program raise EvalError {
  let c = { instrs: [], consts: [], grammar }
  c.compile_node(ast)
  { instrs: c.instrs, consts: c.consts }
}

///|
fn Compiler::emit(self : Compiler, i : Instr) -> Int {
  self.instrs.push(i)
  self.instrs.length() - 1
}

///|
fn Compiler::const_idx(self : Compiler, c : Const) -> Int {
  // Deduplicate values (structural) — cheap pool for common literals.
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
fn Compiler::compile_node(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  match node.node_type {
    @ast.LiteralNode => {
      let idx = self.const_idx(CVal(node.value))
      ignore(self.emit(OpConst(idx)))
    }
    @ast.IdentifierNode =>
      match node.from {
        Some(from) => {
          self.compile_node(from)
          ignore(self.emit(OpFetch(node.ident_name)))
        }
        None =>
          if node.relative {
            ignore(self.emit(OpLoadRel(node.ident_name)))
          } else {
            ignore(self.emit(OpLoadCtx(node.ident_name)))
          }
      }
    @ast.BinaryExpressionNode => self.compile_binary(node)
    @ast.UnaryExpressionNode => {
      match node.right {
        Some(r) => self.compile_node(r)
        None => ()
      }
      ignore(self.emit(OpUnary(node.operator)))
    }
    @ast.ConditionalExpressionNode => {
      match node.cond_test {
        Some(t) => self.compile_node(t)
        None => ()
      }
      let jf = self.emit(OpJumpIfFalse(0))
      match node.consequent {
        Some(c) => self.compile_node(c)
        None => ignore(self.emit(OpConst(self.const_idx(CVal(@ast.UndefVal)))))
      }
      let jend = self.emit(OpJump(0))
      self.instrs[jf] = OpJumpIfFalse(self.instrs.length())
      match node.alternate {
        Some(a) => self.compile_node(a)
        None => ignore(self.emit(OpConst(self.const_idx(CVal(@ast.UndefVal)))))
      }
      self.instrs[jend] = OpJump(self.instrs.length())
    }
    @ast.ArrayLiteralNode => {
      for x in node.array_value {
        self.compile_node(x)
      }
      ignore(self.emit(OpArray(node.array_value.length())))
    }
    @ast.ObjectLiteralNode => {
      let keys : Array[String] = []
      for kv in node.obj_value {
        let (k, v) = kv
        keys.push(k)
        self.compile_node(v)
      }
      let idx = self.const_idx(CKeys(keys))
      ignore(self.emit(OpObject(idx)))
    }
    @ast.FilterExpressionNode => {
      // Callback: the whole filter subtree runs on the tree-walk
      // engine (shared budget); instruction-encoded loops come later.
      let idx = self.const_idx(CAst(node))
      ignore(self.emit(OpFilter(idx)))
    }
    @ast.FunctionCallNode => {
      for a in node.args {
        self.compile_node(a)
      }
      let idx = self.const_idx(
        CFunc(node.func_name, node.pool, node.args.length()),
      )
      ignore(self.emit(OpCallFunc(idx)))
    }
  }
}

///|
fn Compiler::compile_binary(
  self : Compiler,
  node : @ast.AstNode,
) -> Unit raise EvalError {
  let op = node.operator
  // Lazy (manual-eval) operators need unevaluated operands: compile to
  // a tree-walk callback over the whole binary node.
  if find_lazy(self.grammar.on_demand_ops, op) is Some(_) &&
    op != "&&" &&
    op != "||" &&
    op != "??" {
    let idx = self.const_idx(CAst(node))
    ignore(self.emit(OpLazyBinary(idx)))
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
      // pop right, keep left when left falsy; result = left ?: right
      let j = self.emit(OpAndJump(0))
      self.instrs[j] = OpAndJump(self.instrs.length())
    }
    "||" => {
      let j = self.emit(OpOrJump(0))
      self.instrs[j] = OpOrJump(self.instrs.length())
    }
    "??" => {
      let j = self.emit(OpCoalesceJump(0))
      self.instrs[j] = OpCoalesceJump(self.instrs.length())
    }
    "matches" => ignore(self.emit(OpMatches))
    _ => ignore(self.emit(OpBinary(op)))
  }
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
    instrs: program.instrs,
    consts: program.consts,
    pc: 0,
    stack: [],
    grammar,
    context,
    rel_context: context,
    budget: { steps: 0 },
    max_steps,
    max_depth,
  }
  vm.run()
}

///|
priv struct VmState {
  instrs : Array[Instr]
  consts : Array[Const]
  mut pc : Int
  stack : Array[@ast.Value]
  grammar : Grammar
  context : @ast.Value
  rel_context : @ast.Value
  budget : BudgetCell
  max_steps : Int
  max_depth : Int
}

///|
fn VmState::charge(self : VmState) -> Unit raise EvalError {
  self.budget.steps = self.budget.steps + 1
  if self.budget.steps > self.max_steps {
    raise EvalError::EvalErr("memory budget exceeded")
  }
}

///|
fn VmState::pop(self : VmState) -> @ast.Value raise EvalError {
  match self.stack.pop() {
    Some(v) => v
    None => raise EvalError::EvalErr("VM stack underflow")
  }
}

///|
fn VmState::popn(self : VmState, n : Int) -> Array[@ast.Value] raise EvalError {
  let out : Array[@ast.Value] = []
  for _ in 0..<n {
    out.push(self.pop())
  }
  out.rev()
}

///|
/// Callback: run an AST subtree on the tree-walk engine with this
/// VM's shared budget and contexts.
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
  }
  e.eval(ast)
}

///|
fn VmState::run(self : VmState) -> @ast.Value raise EvalError {
  let n = self.instrs.length()
  while self.pc < n {
    self.charge()
    match self.instrs[self.pc] {
      OpConst(i) => {
        match self.consts[i] {
          CVal(v) => self.stack.push(v)
          _ => raise EvalError::EvalErr("VM: bad constant")
        }
        self.pc += 1
      }
      OpLoadCtx(key) => {
        self.stack.push(key_of_value(self.context, key))
        self.pc += 1
      }
      OpLoadRel(key) => {
        self.stack.push(key_of_value(self.rel_context, key))
        self.pc += 1
      }
      OpFetch(name) => {
        let from = self.pop()
        self.stack.push(fetch_from(from, name))
        self.pc += 1
      }
      OpBinary(op) => {
        let r = self.pop()
        let l = self.pop()
        self.stack.push(apply_binary_op(self.grammar, op, l, r))
        self.pc += 1
      }
      OpMatches => {
        let pattern = self.pop()
        let s = self.pop()
        let p = match pattern {
          @ast.StrVal(p) => p
          _ => raise EvalError::EvalErr("matches: pattern must be a string")
        }
        self.stack.push(
          @ast.BoolVal(grammar_regex_match(self.grammar, to_string(s), p)),
        )
        self.pc += 1
      }
      OpAndJump(addr) => {
        let v = self.stack[self.stack.length() - 1]
        if truthy(v) {
          ignore(self.pop())
          self.pc += 1
        } else {
          self.pc = addr
        }
      }
      OpOrJump(addr) => {
        let v = self.stack[self.stack.length() - 1]
        if truthy(v) {
          self.pc = addr
        } else {
          ignore(self.pop())
          self.pc += 1
        }
      }
      OpCoalesceJump(addr) => {
        let v = self.stack[self.stack.length() - 1]
        match v {
          @ast.NullVal | @ast.UndefVal => {
            ignore(self.pop())
            self.pc += 1
          }
          _ => self.pc = addr
        }
      }
      OpJump(addr) => self.pc = addr
      OpJumpIfFalse(addr) => {
        let v = self.pop()
        if truthy(v) {
          self.pc += 1
        } else {
          self.pc = addr
        }
      }
      OpUnary(op) => {
        let v = self.pop()
        match find_un(self.grammar.unary_ops, op) {
          Some(f) => {
            self.stack.push(f(v))
            self.pc += 1
          }
          None =>
            raise EvalError::EvalErr("Unary operator " + op + " is not defined")
        }
      }
      OpArray(cnt) => {
        let items = self.popn(cnt)
        self.stack.push(@ast.ArrayVal(items))
        self.pc += 1
      }
      OpObject(idx) =>
        match self.consts[idx] {
          CKeys(keys) => {
            let vals = self.popn(keys.length())
            let pairs : Array[(String, @ast.Value)] = []
            for i in 0..<keys.length() {
              pairs.push((keys[i], vals[i]))
            }
            self.stack.push(@ast.ObjectVal(pairs))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad keys constant")
        }
      OpCallFunc(idx) =>
        match self.consts[idx] {
          CFunc(name, pool, argc) => {
            let args = self.popn(argc)
            self.stack.push(call_pool_function(self.grammar, pool, name, args))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad function constant")
        }
      OpFilter(idx) =>
        match self.consts[idx] {
          CAst(node) => {
            self.stack.push(self.walk_eval(node))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad ast constant")
        }
      OpLazyBinary(idx) =>
        match self.consts[idx] {
          CAst(node) => {
            // Run the lazy operator on the tree-walk engine: its
            // evalOnDemand dispatch provides lazy operands backed by
            // shared-budget subtree evaluation.
            self.stack.push(self.walk_eval(node))
            self.pc += 1
          }
          _ => raise EvalError::EvalErr("VM: bad ast constant")
        }
    }
  }
  match self.stack.pop() {
    Some(v) => v
    None => @ast.UndefVal
  }
}
