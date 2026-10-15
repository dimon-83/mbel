// SPDX-License-Identifier: Apache-2.0
// Parser shape parity against expr's own parser_test.go TestParse table.
//
// The corpus is the upstream table's 105 inputs; the expected column is
// produced by parsing each input with the *real* expr parser and rendering
// the AST in mbel's dump() convention (tools/parse_oracle +
// tools/gen_parse_mbt.py). So this asserts that mbel builds the same tree
// shape as expr for the same source, node for node, rather than asserting
// shapes I wrote by hand.
//
// Rows where mbel legitimately differs are listed in parse_want_skips with
// their reason; everything else must match exactly.

///|
/// input -> reason it cannot match yet (documented divergence).
fn parse_want_skips() -> Array[(String, String)] {
  [
    // expr normalizes a constant string index into a member node at parse
    // time; mbel keeps the bracket form and resolves the same lookup in
    // the evaluator.
    ("foo['all']", "index vs member: expr folds a constant string index"),
    // expr turns a bare-identifier map key into a string node at parse
    // time; mbel keeps the identifier and stringifies it in lowering (its
    // parser test pins the identifier form).
    ("{foo:1, bar:2}", "map key: expr stringifies bare identifier keys"),
    ("{foo:1, bar:2, }", "map key: expr stringifies bare identifier keys"),
    ("{foo:1}.bar", "map key: expr stringifies bare identifier keys"),
    // Go namespace syntax (pkg::fn) needs a host namespace concept mbel
    // does not have; the call is rejected at parse time.
    ("::split(\"a,b,c\", \",\")", ":: namespace call (reflection cut)"),
    ("::split(\"a,b,c\", \",\")[0]", ":: namespace call (reflection cut)"),
    // mbel folds unary plus on a literal at parse time.
    ("+0 != -0", "constant folding: mbel drops unary + on a literal"),
    // Elvis: expr desugars to cond(c, c, a) (duplicating the condition
    // node), mbel represents the same meaning as cond(c, ?, a).
    ("true ?: 1; 2; 3", "elvis representation: cond(c,?,a) vs cond(c,c,a)"),
    // expr wraps any non-pointer predicate argument in a PredicateNode;
    // mbel marks only brace-wrapped bodies, so an if/else predicate
    // appears bare.
    (
      "all(ls, if true { 1 } else { 2 })",
      "predicate wrapper: mbel marks only brace-wrapped bodies",
    ),
  ]
}

///|
test "parser: expr TestParse AST shape parity" {
  let skips = parse_want_skips()
  let fails = StringBuilder::new()
  let mut matched = 0
  let mut skipped = 0
  for row in parse_want_cases {
    let (src, want) = row
    let mut reason = ""
    for s in skips {
      let (s_src, s_reason) = s
      if s_src == src {
        reason = s_reason
      }
    }
    if reason != "" {
      skipped = skipped + 1
      continue
    }
    let got : String = try {
      @expr.dump(@expr.parse(src))
    } catch {
      _ => "PARSE-ERROR"
    }
    if got == want {
      matched = matched + 1
    } else {
      fails.write_string(
        "---\n" + src + "\n  got  " + got + "\n  want " + want + "\n",
      )
    }
  }
  let total = parse_want_cases.length()
  let summary = (
    "matched " +
    matched.to_string() +
    "/" +
    total.to_string() +
    " (skipped " +
    skipped.to_string() +
    ")\n" +
    fails.to_string()
  )
  if matched + skipped != total {
    inspect(summary, content="")
  }
}
