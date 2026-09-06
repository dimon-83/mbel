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

///|
fn disasm_of(src : String) -> String raise {
  let node = @expr.compile_expr(src) catch {
    @evaluator.EvalErr(m) => abort("compile: " + m)
  }
  match node {
    Some(n) => {
      let prog = @evaluator.compile_program(
        @evaluator.constant_fold(n),
        @evaluator.default_grammar(),
      ) catch {
        @evaluator.EvalErr(m) => abort("compile_program: " + m)
      }
      @evaluator.disassemble(prog)
    }
    None => abort("empty")
  }
}

///|
fn expect_disasm_contains(src : String, frags : Array[String], label : String) -> Unit raise {
  let text = disasm_of(src)
  for frag in frags {
    if !text.contains(frag) {
      inspect(text, content="disasm(" + label + ") containing '" + frag + "'")
    }
  }
}

///|
test "disassemble: constants and aggregate calls decode" {
  expect_disasm_contains("map(nums, # * 2)", [
    "LOADCTX 0  ; \"nums\"",
    "CALLAGG 1  ; map argc=1 pred",
  ], "aggregate")
  expect_disasm_contains("upper(name)", [
    "CALLFUNC 1  ; upper[functions] argc=1",
  ], "call")
  // constant folding collapses 42+1 to a single literal
  expect_disasm_contains("42 + 1", ["CONST 0  ; 43"], "folded consts")
  expect_disasm_contains("x + 1", ["LOADCTX 0  ; \"x\"", "CONST 1  ; 1"], "consts")
}

///|
test "disassemble: locals, slice, jumps and env" {
  expect_disasm_contains("let n = 2; nums[:n]", [
    "ADDLOCAL 1  ; \"n\"",
    "LOADLOCAL 0",
    "SLICE 2", // flags=2: only the `to` bound is present
    "POPLOCAL 1",
  ], "let slice")
  expect_disasm_contains("$env.age", ["ENV", "FETCH 0  ; \"age\""], "env")
  expect_disasm_contains("1 < 2 && 3", [
    "ANDJUMP", "-> ",
  ], "and jump")
}
