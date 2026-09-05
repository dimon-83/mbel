// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — bitwise functions (expr: bitand bitor
// bitxor bitnand bitnot bitshl bitshr bitushr).
//
// expr's bitwise ops are Int64. mbel's value model is Double, so
// operands round-trip through Int64 (exact within ±2^53); shifts are
// masked to 63 bits like Go.

///|
fn to_int64_arg(
  args : Array[@ast.Value],
  i : Int,
  name : String,
) -> Int64 raise @evaluator.EvalError {
  let x = num(arg(args, i, name), name)
  if x != x || x == 1.0 / 0.0 || x == -1.0 / 0.0 {
    raise @evaluator.EvalErr(name + ": not an integer")
  }
  let t = if x < 0.0 { -(-x).floor() } else { x.floor() }
  if t > 9223372036854775807.0 || t < -9223372036854775808.0 {
    raise @evaluator.EvalErr(name + ": integer out of range")
  }
  t.to_int64()
}

///|
fn from_int64(v : Int64) -> @ast.Value {
  @ast.NumVal(v.to_double())
}

///|
fn bitwise_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "bitand",
      fn(args) {
        from_int64(
          to_int64_arg(args, 0, "bitand") & to_int64_arg(args, 1, "bitand"),
        )
      },
    ),
    (
      "bitor",
      fn(args) {
        from_int64(
          to_int64_arg(args, 0, "bitor") | to_int64_arg(args, 1, "bitor"),
        )
      },
    ),
    (
      "bitxor",
      fn(args) {
        from_int64(
          to_int64_arg(args, 0, "bitxor") ^ to_int64_arg(args, 1, "bitxor"),
        )
      },
    ),
    (
      // expr's bitnand = ~(a & b)
      "bitnand",
      fn(args) {
        from_int64(
          (to_int64_arg(args, 0, "bitnand") & to_int64_arg(args, 1, "bitnand")) ^
          -1L,
        )
      },
    ),
    ("bitnot", fn(args) { from_int64(to_int64_arg(args, 0, "bitnot") ^ -1L) }),
    (
      "bitshl",
      fn(args) {
        from_int64(
          to_int64_arg(args, 0, "bitshl") <<
          (to_int64_arg(args, 1, "bitshl") & 63L).to_int(),
        )
      },
    ),
    (
      "bitshr",
      fn(args) {
        from_int64(
          to_int64_arg(args, 0, "bitshr") >>
          (to_int64_arg(args, 1, "bitshr") & 63L).to_int(),
        )
      },
    ),
    (
      // Logical shift: reinterpret the Int64 bits as UInt64 first
      // (Go uint64(x) >> n), mask the shift count to 63.
      "bitushr",
      fn(args) {
        let u = to_int64_arg(args, 0, "bitushr").to_uint64()
        let n = (to_int64_arg(args, 1, "bitushr") & 63L).to_int()
        from_int64((u >> n).to_int64())
      },
    ),
  ]
}
