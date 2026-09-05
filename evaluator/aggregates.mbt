// SPDX-License-Identifier: Apache-2.0
// mbel — expr-style predicate aggregates (stage 4.4.2).
//
// The 15 aggregate functions share one driver (aggregate_call): the
// only engine-specific part is the predicate runner, injected by the
// calling engine. Walk runs the predicate AST on element evaluators;
// the VM runs a pre-compiled predicate Program on a reused sub-VM
// with typed slots (#, #index, #acc) — the "native aggregate loop".

///|
/// The predicate runner contract: evaluate the predicate for element
/// `elem` at `idx` with reducer accumulator `acc`.
pub type PredRunner = (Int, @ast.Value, @ast.Value) -> @ast.Value raise EvalError

///|
/// Drives an aggregate over `list`. `extra` holds the already-evaluated
/// non-predicate arguments after the list (sortBy order, reduce init).
/// Semantics follow expr-lang's builtin.go.
pub fn aggregate_call(
  name : String,
  list : Array[@ast.Value],
  has_pred : Bool,
  extra : Array[@ast.Value],
  run : PredRunner,
) -> @ast.Value raise EvalError {
  let n = list.length()
  match name {
    "all" => {
      for i in 0..<n {
        if !truthy(run(i, list[i], @ast.UndefVal)) {
          return @ast.BoolVal(false)
        }
      }
      @ast.BoolVal(true)
    }
    "any" => {
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return @ast.BoolVal(true)
        }
      }
      @ast.BoolVal(false)
    }
    "none" => {
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return @ast.BoolVal(false)
        }
      }
      @ast.BoolVal(true)
    }
    "one" => {
      let mut found = 0
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          found += 1
          if found > 1 {
            return @ast.BoolVal(false)
          }
        }
      }
      @ast.BoolVal(found == 1)
    }
    "filter" => {
      let out : Array[@ast.Value] = []
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          out.push(list[i])
        }
      }
      @ast.ArrayVal(out)
    }
    "map" => {
      let out : Array[@ast.Value] = []
      for i in 0..<n {
        out.push(run(i, list[i], @ast.UndefVal))
      }
      @ast.ArrayVal(out)
    }
    "count" => {
      if !has_pred {
        @ast.NumVal(n.to_double())
      } else {
        let mut c = 0
        for i in 0..<n {
          if truthy(run(i, list[i], @ast.UndefVal)) {
            c += 1
          }
        }
        @ast.NumVal(c.to_double())
      }
    }
    "sum" => {
      let mut total = 0.0
      for i in 0..<n {
        let v = if has_pred { run(i, list[i], @ast.UndefVal) } else { list[i] }
        total += to_number(v)
      }
      @ast.NumVal(total)
    }
    "find" => {
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return list[i]
        }
      }
      @ast.NullVal
    }
    "findIndex" => {
      for i in 0..<n {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return @ast.NumVal(i.to_double())
        }
      }
      @ast.NullVal
    }
    "findLast" => {
      let mut i = n - 1
      while i >= 0 {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return list[i]
        }
        i -= 1
      }
      @ast.NullVal
    }
    "findLastIndex" => {
      let mut i = n - 1
      while i >= 0 {
        if truthy(run(i, list[i], @ast.UndefVal)) {
          return @ast.NumVal(i.to_double())
        }
        i -= 1
      }
      @ast.NullVal
    }
    "groupBy" => {
      let out : Array[(String, @ast.Value)] = []
      let order : Array[String] = []
      for i in 0..<n {
        let key = to_string(run(i, list[i], @ast.UndefVal))
        let mut placed = false
        for j in 0..<out.length() {
          let (k, vs) = out[j]
          if k == key {
            match vs {
              @ast.ArrayVal(xs) => xs.push(list[i])
              _ => ()
            }
            placed = true
            break
          }
        }
        if !placed {
          out.push((key, @ast.ArrayVal([list[i]])))
          order.push(key)
        }
      }
      @ast.ObjectVal(out)
    }
    "sortBy" => {
      // Evaluate keys once, then sort element/key pairs.
      let keys : Array[@ast.Value] = []
      for i in 0..<n {
        keys.push(run(i, list[i], @ast.UndefVal))
      }
      let order = match extra.get(0) {
        Some(@ast.StrVal(o)) => o
        _ => "asc"
      }
      let idxs : Array[Int] = []
      for i in 0..<n {
        idxs.push(i)
      }
      idxs.sort_by(fn(a, b) {
        let c = key_compare(keys[a], keys[b])
        if order == "desc" { -c } else { c }
      })
      let out : Array[@ast.Value] = []
      for i in idxs {
        out.push(list[i])
      }
      @ast.ArrayVal(out)
    }
    "reduce" => {
      if n == 0 {
        return match extra.get(0) {
          Some(init) => init
          None => @ast.NullVal
        }
      }
      // expr semantics: without an explicit init, #acc starts as the
      // first element and iteration begins at index 1.
      let mut acc : @ast.Value = @ast.UndefVal
      let start : Int = match extra.get(0) {
        Some(init) => {
          acc = init
          0
        }
        None => {
          acc = list[0]
          1
        }
      }
      for i in start..<n {
        acc = run(i, list[i], acc)
      }
      acc
    }
    _ => raise EvalError::EvalErr("unknown aggregate " + name)
  }
}

///|
/// Comparison for sortBy keys: numbers numerically, strings
/// lexicographically, anything else falls back to string form.
fn key_compare(a : @ast.Value, b : @ast.Value) -> Int {
  match (a, b) {
    (@ast.NumVal(x), @ast.NumVal(y)) =>
      if x < y { -1 } else if x > y { 1 } else { 0 }
    (@ast.StrVal(x), @ast.StrVal(y)) => lex_compare(x, y)
    (_, _) => lex_compare(to_string(a), to_string(b))
  }
}
