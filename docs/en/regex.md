# Regular expressions (`matches`)

`matches` is the regex operator. Its right operand is an
[RE2](https://github.com/google/re2/wiki/Syntax) pattern, translated at
evaluation time into the dialect of the MoonBit core regex engine.
Everything on this page is measured against Go's `regexp` — the reference
implementation expr itself uses — by a differential corpus of **222
cases** run on both execution engines (Walk and Vm), so the supported
surface is verified rather than claimed.

```text
"xabcx" matches "abc"          // true  — a search, not a full match
"abc"   matches "^abc$"        // true  — anchor when you want a full match
"Ünïcode" matches "^\p{L}+$"   // true  — Unicode classes
"2024-01-01" matches "^\d{4}-\d{2}-\d{2}$"   // true
"a.b"   matches "\Qa.b\E"      // true  — quoted literal
```

## The operator

- Precedence 20, alongside the comparison operators; identical in both
  dialects.
- **Search semantics**, like RE2 and expr: the pattern may match anywhere
  in the subject. Anchor with `^…$` for a whole-string test.
- A non-string **subject** is converted to a string: `1 matches "1"` is
  `true`. A `nil` subject answers `false` (nil-safe like `contains`); it is
  not converted to `"nil"`.
- The **pattern must be a string**: `"abc" matches 1` raises
  `matches: pattern must be a string`.
- An empty pattern matches everything (`"x" matches ""` is `true`).
- `contains`, `startsWith` and `endsWith` are **plain string operators**,
  not regex — `"a.c" contains "."` is a literal dot test.

## Supported syntax

| Construct | Forms | Notes |
|---|---|---|
| Literals | `abc` | concatenation implicit; `\.` `\*` `\\` `\n` `\t` … escape metacharacters |
| Alternation | `a\|b` | |
| Quantifiers | `*` `+` `?` `{n}` `{n,}` `{n,m}` | lazy variants `*?` `+?` `??` `{n,m}?` |
| Groups | `(…)` `(?:…)` `(?<name>…)` `(?P<name>…)` | Go's two named-group spellings both work |
| Anchors | `^` `$` `\A` `\z` | `\A` is translated to `^` and `\z` to `$`; `$` is end-of-text (not "before a final newline", unlike JS/Python) |
| Word boundaries | `\b` `\B` | |
| Any character | `.` | every character except newline; `(?s)` or `(?s:…)` includes newline |
| Classes | `[…]` `[^…]` `[a-z]` | a leading or trailing `-` is literal; `\u{…}` ranges work, astral ones included |
| POSIX classes | `[[:alpha:]]` `[[:digit:]]` … | all **14** RE2 names; `cntrl`, `graph`, `print` and `punct` are expanded to RE2's ASCII definitions (see below) |
| Shorthand escapes | `\d` `\D` `\w` `\W` `\s` `\S` | ASCII sets as in RE2 — `\d` is `[0-9]`, so `"٣" matches "\d"` is `false` |
| Hex escapes | `\xHH` `\x{H…}` | translated to core's `\u00HH` / `\u{H…}` |
| Quoted literal | `\Q…\E` | the enclosed text is matched literally; a missing `\E` quotes to the end of the pattern |
| Unicode classes | `\p{L}` `\p{Lu}` `\p{Greek}` `\p{Han}` `\p{Any}` `\pL` `\P{…}` | general categories **and** scripts, also inside a class; ranges come from Go's own `unicode` tables |
| Flags | `(?i)` `(?i:…)` `(?s)` `(?s:…)` | case-insensitivity and dot-all, bare (rest of the pattern) or scoped |

RE2's fourteen POSIX names are `alnum alpha ascii blank cntrl digit graph
lower print punct space upper word xdigit`. Ten are native in core; the
other four are rewritten to RE2's ASCII ranges, so `[[:punct:]]` matches
`! " # … ~` and `[[:cntrl:]]` matches `\x00–\x1F` and `\x7F` exactly as
Go does.

## Documented cuts

Each raises an actionable `invalid regex: …` naming the construct, rather
than matching something subtly different:

| Cut | Why | Use instead |
|---|---|---|
| `(?m)` multiline | core has no multiline mode | explicit anchors, or split the input per line |
| `\D` `\W` `\S` **inside a class** | needs character-class set algebra | negate the whole class (`[^[:digit:]]`) or list the set |
| `\P{…}` **inside a class** | same reason | write the class complement (`[^…]`) |
| `\Q…\E` **inside a class** | core has no quoting escape there | escape the literal characters |
| `[[:^name:]]` | core rejects the negated POSIX form | write `[^[:name:]]` |
| `(?U)` ungreedy mode | no core equivalent | write the lazy quantifiers explicitly |
| `(?-i)` inside an active `(?i)` scope | core only implements `(?i:…)` | split the pattern, or spell the case set out |

Lookaround (`(?=…)`, `(?!…)`, `(?<=…)`, `(?<!…)`) and backreferences
(`\1`) are rejected too — and RE2 rejects them as well, so that matches
expr rather than diverging from it. `\Z`, `\G` and anchors or
backreferences inside a class are rejected for the same reason (core would
otherwise read `[a\A]` as the literal `A`).

## Known divergences from expr

Both are deliberate, documented and covered by tests:

- **`(?i)` folds ASCII only.** `"Ä" matches "(?i)ä"` is `false` in mbel
  and `true` in expr, because core's case-insensitive matching is ASCII
  (Unicode folding would need a fold table). Workaround: spell the
  alternatives (`[aAäÄ]`) or combine classes (`\p{Lu}|\p{Ll}`).
- **`\uXXXX` and `\u{…}` are accepted.** RE2 rejects them; mbel accepts
  them as code-point escapes (the translator emits the same form), so this
  is a superset — never a silently different meaning.

## Errors

One shape, with the failing construct named and the underlying diagnostic
passed through:

```text
invalid regex: <pattern> (<reason>)
```

```text
(?m)^a     →  invalid regex: (?m)^a (unsupported regex construct (?m): multiline mode is not supported …)
[\D]       →  invalid regex: [\D] (unsupported regex construct \D inside a character class: …)
[[:^alpha:]] →  invalid regex: [[:^alpha:]] (ParserError at position 1: Invalid POSIX character class)
a**        →  invalid regex: a** (ParserError at position 2: Unexpected character)
[z-a]      →  invalid regex: [z-a] (ParserError at position 3: Invalid character class range)
\p{Nope}   →  invalid regex: \p{Nope} (invalid regex: unknown Unicode class Nope)
```

## Caching and resources

- Compiled patterns are cached **per engine instance**, keyed by pattern
  text, so a repeated `matches` in a loop compiles once.
- The cache is capacity-bounded: **256** compiled patterns and **64**
  remembered failures (`regex_cache_capacity()`,
  `regex_failed_capacity()`); when full, the older half is dropped so
  inserts stay amortized O(1).
- An embedder that feeds unbounded dynamic patterns can call
  `Engine::clear_caches()` on its own schedule instead of waiting for the
  engine to be dropped.
- Matching is linear-time RE2-style: there is no backtracking, so a
  hostile pattern cannot blow up with input size. A pattern that arrives
  as a *dynamic* value is not length-capped beyond the cache behaviour, so
  treat untrusted pattern sources like any other untrusted input.

## How the translation works

mbel depends only on `moonbitlang/core`, whose regex engine speaks its own
dialect (POSIX classes, `\u{…}`, no `\p{…}`, no `(?m)`).
`evaluator/regex_translate.mbt` rewrites the RE2 constructs that have an
exact core equivalent and raises a named error for the rest.
`evaluator/unicode_classes.mbt` holds the Unicode category and script
tables, generated from Go's `unicode` package — which is why `\p{…}`
agrees with expr by construction.

Regenerating the artefacts:

```text
python3 tools/gen_regex_mbt.py     # corpus → expr_test data, via Go's regexp
cd tools/unicode_oracle && go run . ../../evaluator/unicode_classes.mbt
```

`tools/regex_corpus.txt` holds the differential cases and
`tools/regex_oracle.go` evaluates them with Go's `regexp`; see
[tools/README.md](../../tools/README.md).

## Related

- [Language definition](language-definition.md) — operator table and the
  full expression grammar.
- [Custom functions](functions.md) — the builtin context and
  dialect-sensitive builtins.

Back to the [documentation index](README.md).
