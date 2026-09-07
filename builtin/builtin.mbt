// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — the expr-style builtin function set.
//
// These mirror expr-lang/expr's builtin.go for the pure-computation
// surface (math, strings, collections, conversions, bitwise, minimal
// time). Predicate aggregates (all/any/one/none/filter/map/count/
// find*/groupBy/sortBy/reduce) require the expr predicate syntax and
// land with the language front-end (stage 4.4.2).

///|
/// All builtin functions as (name, fn) pairs for the Jexl function
/// pool. Function-call syntax `abs(-5)` resolves through the pool,
/// matching expr's call syntax.
pub fn functions() -> Array[(String, @evaluator.FnA)] {
  math_functions() +
  string_functions() +
  collection_functions() +
  conversion_functions() +
  bitwise_functions() +
  time_functions()
}

///|
fn math_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "abs",
      fn(args) {
        // expr: abs of an int stays int (MinInt wraps like Go)
        match arg(args, 0, "abs") {
          @ast.IntVal(i) => @ast.IntVal(if i < 0L { -i } else { i })
          other => {
            let x = num(other, "abs")
            @ast.NumVal(if x < 0.0 { -x } else { x })
          }
        }
      },
    ),
    ("ceil", fn(args) { @ast.NumVal(num(arg(args, 0, "ceil"), "ceil").ceil()) }),
    (
      "floor",
      fn(args) { @ast.NumVal(num(arg(args, 0, "floor"), "floor").floor()) },
    ),
    (
      "round",
      fn(args) { @ast.NumVal(go_round(num(arg(args, 0, "round"), "round"))) },
    ),
    (
      "max",
      fn(args) {
        // expr: max of ints stays int
        let vs = flat_values(args)
        if vs.length() == 0 {
          raise @evaluator.EvalErr("max: no arguments")
        }
        if all_ints(vs) {
          let mut best = match vs[0] {
            @ast.IntVal(i) => i
            _ => 0L
          }
          for v in vs {
            match v {
              @ast.IntVal(i) => if i > best { best = i }
              _ => ()
            }
          }
          @ast.IntVal(best)
        } else {
          let xs = collect_numbers(args, "max")
          let mut best = xs[0]
          for x in xs {
            if x > best {
              best = x
            }
          }
          @ast.NumVal(best)
        }
      },
    ),
    (
      "min",
      fn(args) {
        let vs = flat_values(args)
        if vs.length() == 0 {
          raise @evaluator.EvalErr("min: no arguments")
        }
        if all_ints(vs) {
          let mut best = match vs[0] {
            @ast.IntVal(i) => i
            _ => 0L
          }
          for v in vs {
            match v {
              @ast.IntVal(i) => if i < best { best = i }
              _ => ()
            }
          }
          @ast.IntVal(best)
        } else {
          let xs = collect_numbers(args, "min")
          let mut best = xs[0]
          for x in xs {
            if x < best {
              best = x
            }
          }
          @ast.NumVal(best)
        }
      },
    ),
    (
      "mean",
      fn(args) {
        let xs = collect_numbers(args, "mean")
        if xs.length() == 0 {
          raise @evaluator.EvalErr("mean: no arguments")
        }
        let mut sum = 0.0
        for x in xs {
          sum += x
        }
        @ast.NumVal(sum / xs.length().to_double())
      },
    ),
    (
      "median",
      fn(args) {
        let xs = collect_numbers(args, "median")
        if xs.length() == 0 {
          raise @evaluator.EvalErr("median: no arguments")
        }
        let sorted = sort_doubles(xs)
        let n = sorted.length()
        let mid = if n % 2 == 1 {
          sorted[n / 2]
        } else {
          (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        }
        @ast.NumVal(mid)
      },
    ),
  ]
}

///|
fn sort_doubles(xs : Array[Double]) -> Array[Double] {
  let out = xs.copy()
  out.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  out
}

///|
fn string_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "trim",
      fn(args) {
        @ast.StrVal(to_str(arg(args, 0, "trim"), "trim").trim().to_owned())
      },
    ),
    (
      "trimPrefix",
      fn(args) {
        let s = to_str(arg(args, 0, "trimPrefix"), "trimPrefix")
        let p = to_str(arg(args, 1, "trimPrefix"), "trimPrefix")
        if s.has_prefix(p) {
          @ast.StrVal(s[p.length():].to_owned())
        } else {
          @ast.StrVal(s)
        }
      },
    ),
    (
      "trimSuffix",
      fn(args) {
        let s = to_str(arg(args, 0, "trimSuffix"), "trimSuffix")
        let p = to_str(arg(args, 1, "trimSuffix"), "trimSuffix")
        if s != "" && s.has_suffix(p) {
          @ast.StrVal(s[:s.length() - p.length()].to_owned())
        } else {
          @ast.StrVal(s)
        }
      },
    ),
    (
      "upper",
      fn(args) {
        @ast.StrVal(to_upper_ascii(to_str(arg(args, 0, "upper"), "upper")))
      },
    ),
    (
      "lower",
      fn(args) {
        @ast.StrVal(to_lower_ascii(to_str(arg(args, 0, "lower"), "lower")))
      },
    ),
    (
      "split",
      fn(args) {
        let s = to_str(arg(args, 0, "split"), "split")
        let sep = to_str(arg(args, 1, "split"), "split")
        let parts : Array[@ast.Value] = []
        for p in s.split(sep) {
          parts.push(@ast.StrVal(p.to_owned()))
        }
        @ast.ArrayVal(parts)
      },
    ),
    (
      "splitAfter",
      fn(args) {
        let s = to_str(arg(args, 0, "splitAfter"), "splitAfter")
        let sep = to_str(arg(args, 1, "splitAfter"), "splitAfter")
        let raw : Array[String] = s
          .split(sep)
          .map(fn(p) { p.to_owned() })
          .collect()
        let parts : Array[@ast.Value] = []
        let n = raw.length()
        for i in 0..<n {
          let piece = if i < n - 1 && sep != "" { raw[i] + sep } else { raw[i] }
          parts.push(@ast.StrVal(piece))
        }
        @ast.ArrayVal(parts)
      },
    ),
    (
      "replace",
      fn(args) {
        let s = to_str(arg(args, 0, "replace"), "replace")
        let old = to_str(arg(args, 1, "replace"), "replace")
        let new = to_str(arg(args, 2, "replace"), "replace")
        @ast.StrVal(replace_all(s, old, new))
      },
    ),
    (
      "repeat",
      fn(args) {
        let s = to_str(arg(args, 0, "repeat"), "repeat")
        let n = num(arg(args, 1, "repeat"), "repeat")
        // expr caps repeat at 1e6 as well.
        if n < 0.0 || n != n.floor() || n > 1000000.0 {
          raise @evaluator.EvalErr("repeat: invalid count")
        }
        let out = StringBuilder::new()
        for _ in 0..<n.to_int() {
          out.write_string(s)
        }
        @ast.StrVal(out.to_string())
      },
    ),
    (
      "join",
      fn(args) {
        let arr = arg(args, 0, "join")
        let sep = to_str(arg(args, 1, "join"), "join")
        match arr {
          @ast.ArrayVal(xs) => {
            let out = StringBuilder::new()
            for i in 0..<xs.length() {
              if i > 0 {
                out.write_string(sep)
              }
              out.write_string(@evaluator.to_string(xs[i]))
            }
            @ast.StrVal(out.to_string())
          }
          _ => raise @evaluator.EvalErr("join: expected an array")
        }
      },
    ),
    (
      "indexOf",
      fn(args) {
        let s = to_str(arg(args, 0, "indexOf"), "indexOf")
        let sub = to_str(arg(args, 1, "indexOf"), "indexOf")
        @ast.IntVal(@evaluator.index_of(s, sub).to_int64())
      },
    ),
    (
      "lastIndexOf",
      fn(args) {
        let s = to_str(arg(args, 0, "lastIndexOf"), "lastIndexOf")
        let sub = to_str(arg(args, 1, "lastIndexOf"), "lastIndexOf")
        @ast.IntVal(last_index_of(s, sub).to_int64())
      },
    ),
    (
      "hasPrefix",
      fn(args) {
        let s = to_str(arg(args, 0, "hasPrefix"), "hasPrefix")
        let p = to_str(arg(args, 1, "hasPrefix"), "hasPrefix")
        @ast.BoolVal(s.has_prefix(p))
      },
    ),
    (
      "hasSuffix",
      fn(args) {
        let s = to_str(arg(args, 0, "hasSuffix"), "hasSuffix")
        let p = to_str(arg(args, 1, "hasSuffix"), "hasSuffix")
        @ast.BoolVal(s.has_suffix(p))
      },
    ),
    (
      "string",
      fn(args) { @ast.StrVal(@evaluator.to_string(arg(args, 0, "string"))) },
    ),
  ]
}

///|
fn collection_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "len",
      // expr: len always returns an int
      fn(args) { @ast.IntVal(value_len(arg(args, 0, "len")).to_int64()) },
    ),
    (
      "first",
      fn(args) {
        match arg(args, 0, "first") {
          @ast.ArrayVal(xs) =>
            if xs.length() > 0 {
              xs[0]
            } else {
              @ast.NullVal
            }
          @ast.BytesVal(b) =>
            if b.length() > 0 {
              @ast.IntVal(b[0].to_int().to_int64())
            } else {
              @ast.NullVal
            }
          _ => @ast.NullVal
        }
      },
    ),
    (
      "last",
      fn(args) {
        match arg(args, 0, "last") {
          @ast.ArrayVal(xs) =>
            if xs.length() > 0 {
              xs[xs.length() - 1]
            } else {
              @ast.NullVal
            }
          @ast.BytesVal(b) =>
            if b.length() > 0 {
              @ast.IntVal(b[b.length() - 1].to_int().to_int64())
            } else {
              @ast.NullVal
            }
          _ => @ast.NullVal
        }
      },
    ),
    (
      "get",
      fn(args) {
        let subject = arg(args, 0, "get")
        let key = arg(args, 1, "get")
        let fallback = if args.length() > 2 { args[2] } else { @ast.NullVal }
        match (subject, key) {
          (@ast.ArrayVal(xs), @ast.NumVal(d)) =>
            if d == d.floor() && d >= 0.0 {
              let i = d.to_int()
              if i < xs.length() {
                xs[i]
              } else {
                fallback
              }
            } else {
              fallback
            }
          (@ast.ObjectVal(pairs), @ast.StrVal(k)) => {
            for pair in pairs {
              let (key0, v) = pair
              if key0 == k {
                return v
              }
            }
            fallback
          }
          (_, _) => fallback
        }
      },
    ),
    (
      "take",
      fn(args) {
        let arr = arg(args, 0, "take")
        let n = num(arg(args, 1, "take"), "take")
        match arr {
          @ast.ArrayVal(xs) => {
            let k = if n < 0.0 {
              0
            } else if n > xs.length().to_double() {
              xs.length()
            } else {
              n.to_int()
            }
            let head : Array[@ast.Value] = []
            for i in 0..<k {
              head.push(xs[i])
            }
            @ast.ArrayVal(head)
          }
          _ => raise @evaluator.EvalErr("take: expected an array")
        }
      },
    ),
    (
      "keys",
      fn(args) {
        match arg(args, 0, "keys") {
          @ast.ObjectVal(pairs) => {
            let ks : Array[@ast.Value] = []
            for pair in pairs {
              let (k, _) = pair
              ks.push(@ast.StrVal(k))
            }
            @ast.ArrayVal(ks)
          }
          _ => raise @evaluator.EvalErr("keys: expected a map")
        }
      },
    ),
    (
      "values",
      fn(args) {
        match arg(args, 0, "values") {
          @ast.ObjectVal(pairs) => {
            let vs : Array[@ast.Value] = []
            for pair in pairs {
              let (_, v) = pair
              vs.push(v)
            }
            @ast.ArrayVal(vs)
          }
          _ => raise @evaluator.EvalErr("values: expected a map")
        }
      },
    ),
    (
      "reverse",
      fn(args) {
        match arg(args, 0, "reverse") {
          @ast.ArrayVal(xs) => {
            let out : Array[@ast.Value] = []
            let mut i = xs.length() - 1
            while i >= 0 {
              out.push(xs[i])
              i -= 1
            }
            @ast.ArrayVal(out)
          }
          @ast.StrVal(s) => {
            let chars = s.to_array()
            let out = StringBuilder::new()
            let mut i = chars.length() - 1
            while i >= 0 {
              out.write_char(chars[i])
              i -= 1
            }
            @ast.StrVal(out.to_string())
          }
          _ => raise @evaluator.EvalErr("reverse: expected an array or string")
        }
      },
    ),
    (
      "uniq",
      fn(args) {
        match arg(args, 0, "uniq") {
          @ast.ArrayVal(xs) => {
            let out : Array[@ast.Value] = []
            for x in xs {
              let mut seen = false
              for y in out {
                if @ast.value_equal(x, y) {
                  seen = true
                  break
                }
              }
              if !seen {
                out.push(x)
              }
            }
            @ast.ArrayVal(out)
          }
          _ => raise @evaluator.EvalErr("uniq: expected an array")
        }
      },
    ),
    (
      "concat",
      fn(args) {
        let out : Array[@ast.Value] = []
        for a in args {
          match a {
            @ast.ArrayVal(xs) =>
              for x in xs {
                out.push(x)
              }
            _ => raise @evaluator.EvalErr("concat: expected arrays")
          }
        }
        @ast.ArrayVal(out)
      },
    ),
    (
      "flatten",
      fn(args) { @ast.ArrayVal(flatten_value(arg(args, 0, "flatten"), 0)) },
    ),
    (
      "sort",
      fn(args) {
        match arg(args, 0, "sort") {
          @ast.ArrayVal(xs) => @ast.ArrayVal(sort_values(xs))
          _ => raise @evaluator.EvalErr("sort: expected an array")
        }
      },
    ),
  ]
}

///|
/// expr's flatten with MaxDepth protection (10000).
fn flatten_value(
  v : @ast.Value,
  depth : Int,
) -> Array[@ast.Value] raise @evaluator.EvalError {
  if depth > 10000 {
    raise @evaluator.EvalErr("cannot flatten nested array: max depth reached")
  }
  match v {
    @ast.ArrayVal(xs) => {
      let out : Array[@ast.Value] = []
      for x in xs {
        match x {
          @ast.ArrayVal(_) =>
            for y in flatten_value(x, depth + 1) {
              out.push(y)
            }
          other => out.push(other)
        }
      }
      out
    }
    _ => raise @evaluator.EvalErr("flatten: expected an array")
  }
}

///|
fn conversion_functions() -> Array[(String, @evaluator.FnA)] {
  [
    (
      "int",
      fn(args) {
        // expr int() truncates toward zero and returns an int.
        match arg(args, 0, "int") {
          @ast.IntVal(i) => @ast.IntVal(i)
          other => {
            let x = num(other, "int")
            let t = if x < 0.0 { -(-x).floor() } else { x.floor() }
            @ast.IntVal(t.to_int64())
          }
        }
      },
    ),
    ("float", fn(args) { @ast.NumVal(num(arg(args, 0, "float"), "float")) }),
    (
      "type",
      fn(args) {
        @ast.StrVal(
          // expr parity (4.4.3): typed integers report "int". Floats
          // report "number" on the legacy path (locked by legacy
          // tests) where expr would say "float" — documented
          // divergence until the strict-engine split (4.4.5).
          match arg(args, 0, "type") {
            @ast.BoolVal(_) => "bool"
            @ast.NumVal(_) => "number"
            @ast.IntVal(_) => "int"
            @ast.StrVal(_) => "string"
            // expr reports "array" for []byte too
            @ast.BytesVal(_) => "array"
            @ast.NullVal => "nil"
            @ast.UndefVal => "unknown"
            @ast.ArrayVal(_) => "array"
            @ast.ObjectVal(_) => "map"
          },
        )
      },
    ),
    (
      "toJSON",
      fn(args) {
        @ast.StrVal(
          // exact int64 digits (expr/Go json); NaN/Inf -> null
          to_json_string(arg(args, 0, "toJSON")),
        )
      },
    ),
    (
      "fromJSON",
      fn(args) {
        let s = to_str(arg(args, 0, "fromJSON"), "fromJSON")
        let j = @json.parse(s) catch {
          _ => raise @evaluator.EvalErr("fromJSON: invalid JSON")
        }
        json_to_value(j)
      },
    ),
    (
      "toBase64",
      fn(args) {
        @ast.StrVal(encode64(to_str(arg(args, 0, "toBase64"), "toBase64")))
      },
    ),
    (
      "fromBase64",
      fn(args) {
        @ast.StrVal(decode64(to_str(arg(args, 0, "fromBase64"), "fromBase64")))
      },
    ),
    (
      "toPairs",
      fn(args) {
        match arg(args, 0, "toPairs") {
          @ast.ObjectVal(pairs) => {
            let out : Array[@ast.Value] = []
            for pair in pairs {
              let (k, v) = pair
              out.push(@ast.ArrayVal([@ast.StrVal(k), v]))
            }
            @ast.ArrayVal(out)
          }
          _ => raise @evaluator.EvalErr("toPairs: expected a map")
        }
      },
    ),
    (
      "fromPairs",
      fn(args) {
        match arg(args, 0, "fromPairs") {
          @ast.ArrayVal(xs) => {
            let out : Array[(String, @ast.Value)] = []
            for x in xs {
              match x {
                @ast.ArrayVal(pair) if pair.length() >= 2 =>
                  match pair[0] {
                    @ast.StrVal(k) => out.push((k, pair[1]))
                    _ =>
                      raise @evaluator.EvalErr(
                        "fromPairs: key must be a string",
                      )
                  }
                _ =>
                  raise @evaluator.EvalErr(
                    "fromPairs: expected [key, value] pairs",
                  )
              }
            }
            @ast.ObjectVal(out)
          }
          _ => raise @evaluator.EvalErr("fromPairs: expected an array of pairs")
        }
      },
    ),
  ]
}
