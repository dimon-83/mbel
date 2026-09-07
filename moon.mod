// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "dimon-83/mbel"

version = "0.3.0"

readme = "README.mbt.md"

repository = "https://github.com/dimon-83/mbel"

license = "Apache-2.0"

keywords = [ "expression", "jexl", "expr", "evaluator", "dsl" ]

preferred_target = "wasm-gc"

description = "mbel — a MoonBit expression language: Jexl-compatible dynamic evaluation with an expr-lang syntax front-end, dual tree-walk/bytecode-VM engines, predicate aggregates and resource budgets."
