# Language definition

Defines the standard dialect as implemented by mbel (semantic baseline: the
reference language, v1.17.8 — the engineering alignment matrix lives in
docs/coverage-vs-expr.md). Where mbel deviates from the reference, the
deviation is
marked. The machine-checked coverage matrix lives in docs/coverage-vs-expr.md.

Two notes up front:

- **Modes.** Everything below describes `Engine::eval_expr` (Eval mode —
  dynamic env, typed runtime) and `Engine::eval_expr_checked` (Compile mode
  — the same language plus static type errors). The classic dialect (legacy)
  (`Engine::eval`) has different, JS-flavored semantics.
- **Values.** Runtime values are `BoolVal`, `IntVal` (int64), `NumVal`
  (float64), `StrVal`, `ArrayVal`, `ObjectVal`, `NullVal`, `UndefVal`.
  Context data (JSON) produces floats; **integer literals and integer
  arithmetic produce int64**. Typed semantics apply whenever an operand is
  or contains an `IntVal`.

## Literals

- Integers: decimal, `0x` hex, `0o` octal, `0b` binary, `_` separators;
  parsed as int64 — values above `9223372036854775807` are parse errors.
- Floats: `1.5`, `.5`, `5.`, exponents `1e9`/`1.5e-3`.
- Strings: single or double quotes, one shared escape set — `\n \r \t \a
  \b \f \v \\`, the quote char, `\xNN`, `\uXXXX`, `\UXXXXXXXX`, `\u{1-6
  hex}`, octal `\NNN` (≤ `\377`). Invalid escapes, lone surrogates, and
  out-of-range code points are lexer errors; raw newlines inside quoted
  strings are rejected.
- Raw strings: backticks, no escapes, ` `` ` doubles a backtick, real
  newlines allowed.
- Byte strings: `b"..."` / `B'...'` — byte content evaluates as a
  `BytesVal` (escapes: simple set + `\xNN` + octal ≤ `\377`; `\u`
  rejected; non-ASCII UTF-8-encoded): bytewise equality, `len`, indexing
  (negative allowed, out-of-range → nil), slicing (result stays a byte
  string), aggregates/filters iterate the bytes as int elements,
  `toJSON` → base64 string (Go json semantics), `type()` reports
  `"array"`. Type names and error texts mirror expr's `[]uint8`.
  Divergence: `string(b"abc")` prints `97,98,99` (mbel's array
  convention; expr prints Go's `[97 98 99]`).
- Booleans `true`/`false`; `nil`.
- Comments: `//` line and `/* */` block.

## Types and runtime typing (expr parity)

- Arithmetic on two ints stays int (int64, wraps like Go): `+ - * %`.
- Anything with a float promotes to float.
- `/` is **always float division**: `7/2 == 3.5`, `1/0 == +Inf`, `0/0 ==
  NaN` — no divide-by-zero error.
- `%` is integer-only; Go semantics (sign of dividend); `% 0` raises
  `integer divide by zero`.
- `**`/`^` always produce floats (even `2 ** 3`); negative exponents fine.
- Equality/ordering between numbers promote (`1 == 1.0` is true);
  cross-kind equality is false; cross-kind ordering and mixed `+` raise
  `invalid operation: int + string`-style errors at runtime (or at check
  time in Compile mode).
- Unary `-` preserves the operand type (`-5` int, `-5.0` float).
- `type()` reports `"int"` for integers; floats report `"number"` (expr
  says `"float"` — documented divergence while the legacy name is locked).

## Operators

Precedence, highest first (all left-associative unless noted):

| Precedence | Operators | Notes |
|---|---|---|
| 100 | `**` `^` (right-assoc) | power, float result |
| 90 | unary `-` `+` | binds looser than power: `-2**2 = -(2**2)` |
| 60 | `*` `/` `%` | |
| 50 | unary `not` `!` | |
| 30 | `+` `-` | `+` concatenates strings; nothing else mixes |
| 25 | `..` | integer range, inclusive; descending → empty |
| 20 | `==` `!=` `<` `>` `<=` `>=` `in` `matches` `contains` `startsWith` `endsWith` | `not in`/`not matches`/`not contains`… = negated suffix |
| 15 | `&&` `and` | |
| 10 | `\|\|` `or` | |
| 0 | `\|` | pipe: `x \| f(a)` → `f(x, a)`; right side must be a parenthesized call (bare `\| f` and `\| x.m()` are parse errors) |
| — | `??` | precedence 500, left-assoc, **cannot be followed by another operator** at the same level: `1 ?? 2 + 3` is a parse error, `1 + 2 ?? 3` and `(1 ?? 2) + 3` are fine, `a ?? b ?? c` chains |

Other syntax:

- Comparison chaining: `1 < x < 10` = `(1 < x) && (x < 10)` (`< > <= >=`
  only; `==` does not chain).
- Ternary `a ? b : c`, elvis `a ?: b` (truthy test is the result).
- `if cond { seq } else { seq }` — both braces and `else` required;
  branches are full sequences (lets allowed); `if` only starts an
  expression (parenthesize to embed); else-if chains.
- Optional chain `?.` / `?.[` — nil-safe member access (mbel drill-down is
  nil-safe by default).
- Slices `a[1:3]`, `a[:2]`, `a[2:]`, negative bounds (`len + x`), clamping,
  `from > to` → empty; works on arrays and strings (string slices are
  character-based in mbel; expr slices bytes — non-ASCII divergence
  documented).
- `matches` regex: MoonBit core regex is literal-only (documented cut;
  full regex is a roadmap item). `contains`/`startsWith`/`endsWith` are
  operators, nil-safe (nil operand → false).
- `let x = expr; rest` and `a; b; c` sequences — `let` at precedence-0
  sites (top level, parens, arguments, if-branches); lexical scope,
  shadowing allowed (Eval mode); result of a sequence is its last
  expression; sequence/predicate code can read outer lets.
- `$env` — the whole context as a value (`len($env)`, `keys($env)`, member
  access all work; cannot be declared).

## Predicates

Predicate aggregates take a predicate as their second argument; braces are
optional, and `.field` is shorthand for `#.field` (the current element):

```text
filter(users, .age >= 18)
filter(users, {.age >= 18})
map(nums, # * 2)
reduce(nums, #acc + #, 100)
count(nums, # > 2)
```

Pointers: `#` (current element), `#index` (position), `#acc`
(accumulator). `#index`/`#acc` are bound inside the aggregates that define
them; only `#`, `#index` and `#acc` are valid — `#age` is a compile error
"unknown pointer '#age'" (expr parity). Pointers are predicate-only:
outside a predicate context (`# + 1`, `xs[#]`) they are parse errors.

Through a pipe the subject takes call-argument 0, so the first explicit
argument is the predicate:

```text
nums | map(# * 2)
users | filter(.age >= 18) | map(.name) | first()
```

mbel additionally accepts the classic-dialect bracket predicate `items[.price <= 2]`
(filters per element, chainable like any value) — expr has no bracket form
and rejects a bare `.` after `[` (documented extension, see
docs/expr-gap-analysis.md §6).

Predicate aggregates (15): `all none any one filter map count sum find
findIndex findLast findLastIndex groupBy sortBy reduce`.

## Functions

56 builtins + 15 aggregates, listed on the [Functions](functions.md) page;
typed returns follow expr (`len`, `count`, indices, `int()` are ints;
`sum`/`abs`/`min`/`max` preserve integer inputs). Custom functions and
transforms are registered per engine instance (no reflection — see
[Functions](functions.md)).

## Errors and budgets

- Parse errors: `parse error at L:C: message` (location from the source).
- Compile-mode (strict) errors use expr wording and expr's FileError
  layout — "msg (L:C)" plus the source line with a caret under the
  offending operator/condition/call: `invalid operation: +
  (mismatched types int and string)`, `non-bool expression (type int) used
  as condition`, `invalid argument for len (type int)`, `unknown name x`.
- Runtime (Eval-mode) typing errors: `invalid operation: int + string`,
  `integer divide by zero`, `slice bounds must be integers`.
- Budgets: node/token limits and recursion guards at parse; depth on both
  engines; step budget at allocation points — messages:
  `expression is too large (more than N nodes)`, `expression is too deeply
  nested`, `expression is too deep (more than N levels)`, `memory budget
  exceeded`.

## Known divergences from expr (summary)

- Env is data only: no struct envs, no methods on values (reflection cut);
  method-call syntax parses but raises at lowering.
- `type()` of floats returns `"number"` (legacy lock) instead of `"float"`.
- String `in` (classic dialect) is substring semantics; the standard dialect
  rejects nothing statically there (Eval mode follows legacy substring
  behavior for strings — divergence documented in coverage matrix).
- String slices are character-based; regex is literal-only; `upper`/`lower`
  are ASCII-only; time is the minimal UTC/ISO subset; JSON numbers are
  doubles (integers above 2^53 lose exactness in context data; literals
  and `toJSON` of int64 are exact).
- `//` is a comment (expr parity), not floor division.
- Bracket predicates `items[.expr]` are accepted (classic-dialect
  compatibility);
  the reference language has no bracket form and rejects a bare `.` after `[`.

Machine-checked status for every row of the expr language definition is in
docs/coverage-vs-expr.md; cut items and rationale in docs/expr-gap-analysis.md.
