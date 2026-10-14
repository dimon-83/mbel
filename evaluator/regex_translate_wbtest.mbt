// SPDX-License-Identifier: Apache-2.0
// Whitebox tests for the RE2 → core pattern translation: the exact
// rewritten text is the unit under test, which only the package can see.

///|
fn tr(pat : String) -> String raise EvalError {
  match translate_re2_pattern(pat) {
    Ok(p) => p
    Err(d) => raise EvalError::EvalErr(d)
  }
}

///|
/// Asserts the pattern is a documented cut and returns its message.
fn tr_cut(pat : String) -> String {
  match translate_re2_pattern(pat) {
    Ok(p) => abort("expected a cut for '" + pat + "', got '" + p + "'")
    Err(d) => d
  }
}

///|
test "regex translate: shorthand class escapes" {
  assert_eq(tr("\\d"), "[[:digit:]]")
  assert_eq(tr("\\D"), "[^[:digit:]]")
  assert_eq(tr("\\w"), "[[:word:]]")
  assert_eq(tr("\\W"), "[^[:word:]]")
  // Go's \s is [\t\n\f\r ] — deliberately excluding \v, unlike
  // core's [[:space:]], so the set is spelled out.
  assert_eq(tr("\\s"), "[\\t\\n\\f\\r ]")
  assert_eq(tr("\\S"), "[^\\t\\n\\f\\r ]")
  // Inside a class the escape becomes a class-body fragment.
  assert_eq(tr("[\\d]"), "[[:digit:]]")
  assert_eq(tr("[\\d\\w]"), "[[:digit:][:word:]]")
  assert_eq(tr("[^\\d]"), "[^[:digit:]]")
  assert_eq(tr("[a\\s]"), "[a\\t\\n\\f\\r ]")
  // Shorthands in context keep the rest of the pattern intact.
  assert_eq(tr("^\\d{4}-\\d{2}$"), "^[[:digit:]]{4}-[[:digit:]]{2}$")
  assert_eq(tr("\\w+@\\w+"), "[[:word:]]+@[[:word:]]+")
}

///|
test "regex translate: dot excludes newline unless dot-all" {
  assert_eq(tr("a.b"), "a[^\\n]b")
  assert_eq(tr(".*"), "[^\\n]*")
  // Inside a class a dot is literal, and \. is an escaped literal.
  assert_eq(tr("[.]"), "[.]")
  assert_eq(tr("\\."), "\\.")
  // (?s) restores RE2 dot-all, which is core's default.
  assert_eq(tr("(?s)a.b"), "a.b")
  assert_eq(tr("(?s:a.b)"), "(?:a.b)")
  assert_eq(tr("(?s)a.b(?-s)c.d"), "a.bc[^\\n]d")
  assert_eq(tr("(?s)a.b(?s)c.d"), "a.bc.d")
}

///|
test "regex translate: character class dash and bracket placement" {
  assert_eq(tr("[a-]"), "[a\\-]")
  assert_eq(tr("[-a]"), "[\\-a]")
  assert_eq(tr("[^-a]"), "[^\\-a]")
  assert_eq(tr("[-]"), "[\\-]")
  assert_eq(tr("[]]"), "[\\]]")
  assert_eq(tr("[^]]"), "[^\\]]")
  // Ranges and interior dashes are untouched.
  assert_eq(tr("[a-z]"), "[a-z]")
  assert_eq(tr("[a-z-]"), "[a-z\\-]")
  assert_eq(tr("[a-z0-9_]"), "[a-z0-9_]")
  // POSIX classes pass through verbatim.
  assert_eq(tr("[[:digit:]]+"), "[[:digit:]]+")
  assert_eq(tr("[[:alpha:][:digit:]]"), "[[:alpha:][:digit:]]")
}

///|
test "regex translate: inline flags" {
  // A bare (?i) applies to the rest of the enclosing group, which core
  // can only express as a (?i:…) wrapper around that remainder.
  assert_eq(tr("(?i)hello"), "(?i:hello)")
  assert_eq(tr("(?i)abc|DEF"), "(?i:abc|DEF)")
  assert_eq(tr("(?i)a(?-i)b"), "(?i:a)b")
  assert_eq(tr("(?i)a(b)c"), "(?i:a(b)c)")
  // The wrapper stops at the enclosing group, so `b` stays case-sensitive.
  assert_eq(tr("((?i)a)b"), "((?i:a))b")
  // Group form is scoped and passed through.
  assert_eq(tr("(?i:hello)"), "(?i:hello)")
  assert_eq(tr("(?is:a.b)"), "(?i:a.b)")
  // (?-s) and <?-m) only touch state this module owns.
  assert_eq(tr("a.b(?-s)"), "a[^\\n]b")
  assert_eq(tr("(?i)a.b(?-s:x)"), "(?i:a[^\\n]b(?:x))")
}

///|
test "regex translate: pass-through of the supported core dialect" {
  assert_eq(tr("abc"), "abc")
  assert_eq(tr("a|b"), "a|b")
  assert_eq(tr("(?:ab)+"), "(?:ab)+")
  assert_eq(tr("(?<n>a)b"), "(?<n>a)b")
  assert_eq(tr("a{2,3}"), "a{2,3}")
  assert_eq(tr("a{2,}"), "a{2,}")
  assert_eq(tr("^a$"), "^a$")
  assert_eq(tr("\\bfoo\\b"), "\\bfoo\\b")
  assert_eq(tr("\\n\\t\\r\\f\\v"), "\\n\\t\\r\\f\\v")
  assert_eq(tr("\\u0041"), "\\u0041")
  assert_eq(tr("\\\\d"), "\\\\d")
}

///|
test "regex translate: documented cuts raise actionable errors" {
  // Unicode property classes.
  assert_true(tr_cut("\\p{L}").contains("Unicode property"))
  assert_true(tr_cut("\\P{Greek}").contains("Unicode property"))
  assert_true(tr_cut("[\\p{L}]").contains("Unicode property"))
  // Multiline mode.
  assert_true(tr_cut("(?m)^a").contains("multiline"))
  assert_true(tr_cut("(?im)a").contains("multiline"))
  assert_true(tr_cut("(?m:a)").contains("multiline"))
  // Negated shorthands inside a class need class set algebra.
  assert_true(tr_cut("[\\D]").contains("[^[:digit:]]"))
  assert_true(tr_cut("[\\W]").contains("[^[:word:]]"))
  assert_true(tr_cut("[\\S]").contains("[^\\t\\n\\f\\r ]"))
  assert_true(tr_cut("[a\\D]").contains("character class"))
  // Turning case-insensitivity off inside a scope this module does not
  // own: a bare (?-i) under an outer (?i:…), and the group form.
  assert_true(tr_cut("(?i:a(?-i)b)").contains("(?-i)"))
  assert_true(tr_cut("(?i)(?-i:a)").contains("(?-i:…)"))
  // \Q…\E, \xHH, (?P<…>), (?U)
  assert_true(tr_cut("\\Qa.b\\E").contains("\\Q"))
  assert_true(tr_cut("\\x41").contains("\\x"))
  assert_true(tr_cut("(?P<n>a)").contains("(?<name>"))
  assert_true(tr_cut("(?U)a+").contains("ungreedy"))
}

///|
test "regex translate: malformed input" {
  // An unbalanced ) is not this module's business — core reports it.
  assert_eq(tr("a)b"), "a)b")
  assert_eq(tr("a)b("), "a)b(")
  // An unterminated class is caught here.
  assert_true(tr_cut("[").contains("unterminated"))
}
