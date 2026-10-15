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
  // A negated Unicode class *inside* a class needs set algebra, like
  // \D/\W/\S there; outside one it is a plain negated class.
  assert_true(tr_cut("[\\P{L}]").contains("class complement"))
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
  // Ungreedy mode has no core equivalent.
  assert_true(tr_cut("(?U)a+").contains("ungreedy"))
}

///|
test "regex translate: Unicode classes expand to core classes" {
  // Go's own range tables back these (evaluator/unicode_classes.mbt), so
  // the expansion has to contain the ranges Go would match.
  assert_true(tr("\\p{L}").has_prefix("["))
  assert_true(tr("\\p{L}").contains("\\u{41}-\\u{5A}"))
  assert_true(tr("\\p{Greek}").contains("\\u{370}-\\u{373}"))
  assert_true(tr("\\p{Han}").contains("\\u{4E00}-\\u{9FFF}"))
  // \pL is the one-letter spelling of \p{L}; \P negates.
  assert_eq(tr("\\pL"), tr("\\p{L}"))
  assert_true(tr("\\P{L}").has_prefix("[^"))
  // Inside a class the ranges are inline (no nested brackets).
  let inline = tr("[\\p{L}5]")
  assert_true(inline.has_prefix("[\\u{"))
  assert_true(!inline.contains("[["))
  assert_true(!inline.contains("]]"))
  assert_true(inline.has_suffix("5]"))
  // Unknown names are reported, not silently matched.
  assert_true(tr_cut("\\p{Nope}").contains("unknown Unicode class"))
  assert_true(tr_cut("\\p{L").contains("unterminated"))
}

///|
test "regex translate: hex, quoted literals and (?P<…>) groups" {
  // \xHH / \x{H…} are code-point escapes; core spells them \u00HH / \u{H…}.
  assert_eq(tr("\\x41"), "\\u0041")
  assert_eq(tr("^\\x41$"), "^\\u0041$")
  assert_eq(tr("\\x{263A}"), "\\u{263A}")
  assert_eq(tr("[\\x41]"), "[\\u0041]")
  assert_eq(tr("[\\x41-\\x5A]"), "[\\u0041-\\u005A]")
  // \Q…\E quotes literally; core has no quoting escape, so the metachars
  // are escaped. A missing \E quotes to the end (as in RE2).
  assert_eq(tr("\\Qa.b\\E"), "a\\.b")
  assert_eq(tr("\\Qa+b\\Ec"), "a\\+bc")
  assert_eq(tr("\\Qa.b"), "a\\.b")
  assert_eq(tr("\\Q\\E"), "")
  // Go accepts both named-group spellings; core only the (?<name>…) one.
  assert_eq(tr("(?P<n>a)b"), "(?<n>a)b")
  assert_eq(tr("(?<n>a)b"), "(?<n>a)b")
  assert_eq(tr("(?P<n>a)|b"), "(?<n>a)|b")
  // Malformed escapes are reported, not passed through.
  assert_true(tr_cut("\\x4").contains("two hex digits"))
  assert_true(tr_cut("\\x{263A").contains("unterminated"))
  assert_true(tr_cut("\\E").contains("without a matching"))
}

///|
test "regex translate: malformed input" {
  // An unbalanced ) is not this module's business — core reports it.
  assert_eq(tr("a)b"), "a)b")
  assert_eq(tr("a)b("), "a)b(")
  // An unterminated class is caught here.
  assert_true(tr_cut("[").contains("unterminated"))
}
