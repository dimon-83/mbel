// SPDX-License-Identifier: Apache-2.0
// mbel — performance benchmarks (moon test --bench -p jexl_test).
// Compile-once/eval-many is the hot path; every bench evaluates the
// full pipeline unless stated otherwise.

///|
fn bench_ctx() -> @ast.Value {
  let items : Array[@ast.Value] = []
  for i in 0..<100 {
    items.push(
      @ast.ObjectVal([
        ("name", @ast.StrVal("item" + i.to_string())),
        ("qty", @ast.NumVal((i % 10).to_double())),
        ("price", @ast.NumVal((i % 7 + 1).to_double())),
      ]),
    )
  }
  @ast.ObjectVal([
    ("x", @ast.NumVal(3.0)),
    (
      "name",
      @ast.ObjectVal([
        ("first", @ast.StrVal("Sterling")),
        ("last", @ast.StrVal("Archer")),
      ]),
    ),
    ("age", @ast.NumVal(36.0)),
    ("items", @ast.ArrayVal(items)),
  ])
}

///|
test "bench compile arithmetic (end-to-end parse+fold)" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  it.bench(() => {
    let r = @jexl.Jexl::eval(inst, "6+x*2>10 ? 'big' : 'small'", bench_ctx()) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench eval identifier chain + filter over 100 items" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  // Compile once, evaluate repeatedly (the hot path for rules engines).
  let expr_obj = @jexl.Jexl::compile(inst, "items[.qty > 2].price") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench eval arithmetic precompiled" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(inst, "2 + 3 * 4 == 5/6 - 7") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench eval nested ternary + logic" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(
    inst, "age > 18 && name.first ?? 'none' ? 'adult' : 'minor'",
  ) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench string builtins" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(
    inst, "upper(trim(\"  hello world  \")) + '|' + replace(\"a,b,c\", \",\", \"-\")",
  ) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench toJSON/fromJSON roundtrip" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let expr_obj = @jexl.Jexl::compile(inst, "fromJSON(toJSON(name))") catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench eval 50-term chain (un-foldable)" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let mut big = "x"
  for _ in 0..<50 {
    big = big + "+1"
  }
  let expr_obj = @jexl.Jexl::compile(inst, big) catch {
    @jexl.JexlErr(msg) => abort(msg)
  }
  let ctx = bench_ctx()
  it.bench(() => {
    let r = @jexl.Expression::eval(expr_obj, ctx) catch {
      @jexl.JexlErr(msg) => abort(msg)
    }
    it.keep(r)
  })
}

///|
test "bench tokenize only (lexer throughput)" (it : @bench.T) {
  let inst = @jexl.new_jexl()
  let src = "6+x*2>10 ? 'big' : 'small'"
  it.bench(() => {
    let r = match @lexer.tokenize_with(src, inst.elements) {
      Ok(toks) => toks.length()
      Err(m) => abort(m)
    }
    it.keep(r)
  })
}
