// Expr aggregate compilation regression: a predicate argument compiles
// to a reusable sub-program (OP_CALLAGG) that runs on the VM with
// typed predicate slots (# / #index / #acc).

///|
test "opcode dump: map(nums, # * 2)" {
  let node = @expr.compile_expr("map(nums, # * 2)") catch {
    @evaluator.EvalErr(m) => abort("compile: " + m)
  }
  match node {
    Some(n) => {
      let folded = @evaluator.constant_fold(n)
      let prog = @evaluator.compile_program(
        folded,
        @evaluator.default_grammar(),
      ) catch {
        @evaluator.EvalErr(m) => abort("compile_program: " + m)
      }
      let names = [
        "CONST", "LOADCTX", "LOADREL", "FETCH", "CALLBINFN", "CALLUNFN", "MATCHES",
        "ANDJ", "ORJ", "COAL", "JUMP", "JIF", "ARRAY", "OBJECT", "CALLFUNC", "FILTERBEGIN",
        "FILTEREND", "FILTERSTATIC", "LAZYBIN", "LOADSLOT", "CALLAGG", "BAD",
      ]
      let mut seq = ""
      for i in 0..<prog.opcodes.length() {
        let op = prog.opcodes[i]
        let name = if op < names.length() {
          names[op]
        } else {
          "OUT(" + op.to_string() + ")"
        }
        seq = seq + name + "(" + prog.operands[i].to_string() + ") "
      }
      inspect(seq, content="LOADCTX(0) CALLAGG(1) ")
      let v = @evaluator.run_program(
        prog,
        @evaluator.default_grammar(),
        @ast.ObjectVal([
          (
            "nums",
            @ast.ArrayVal([@ast.NumVal(1.0), @ast.NumVal(2.0), @ast.NumVal(3.0)]),
          ),
        ]),
        10000,
        1000000,
      ) catch {
        @evaluator.EvalErr(m) => abort("run: " + m)
      }
      inspect(@evaluator.to_string(v), content="2,4,6")
    }
    None => abort("empty")
  }
}
