# mbel — Parity Contract & Semantics Pitfalls

This document captures the public API surface, test fixtures, and JavaScript
semantics pitfalls that must be preserved when porting Jexl to MoonBit.
It is the single source of truth for parity verification.

---

## 1. Public API Surface (from Jexl)

### `Jexl` class (`lib/Jexl.js`)
| Method | Signature | Notes |
|---|---|---|
| `constructor(grammar)` | — | default grammar built-in; custom elements merged |
| `addOp(op)` | `op: ElementDef` | registers a binary/unary operator at runtime |
| `addUnaryOp(op)` | `op: ElementDef` | registers a unary operator |
| `addBinaryOp(op)` | `op: ElementDef` | registers a binary operator |
| `createVar(name)` | `name: string` → `{type:'Variable',value:name}` | AST helper |
| `compile(expr)` | `expr: string` → `Expression` | parse-only, no eval |
| `eval(expr, ctx)` | `expr, ctx` → `Promise<any>` | parse + eval |
| `evalSync(expr, ctx)` | `expr, ctx` → `any` | sync eval (throws on async transforms) |
| `getGrammar()` | → grammar object | returns current grammar |
| `removeOp(op)` | `op: string` | removes operator by symbol |

### `Expression` class (`lib/Expression.js`)
| Method | Signature | Notes |
|---|---|---|
| `constructor(ast, grammar)` | — | wraps parsed AST |
| `eval(context)` | `ctx` → `Promise<any>` | async evaluation |
| `evalSync(context)` | `ctx` → `any` | sync evaluation |

### Grammar elements (from `lib/grammar.js`)
Operators with precedence (lower number = binds tighter):
| Symbol | Type | Precedence |
|---|---|---|
| `//` | binaryOp | 1 (highest) |
| `*` / `/` / `%` | binaryOp | 2 |
| `+` / `-` | binaryOp | 3 |
| `<=` / `<` / `>` / `>=` | binaryOp | 4 |
| `==` / `!=` | binaryOp | 5 |
| `&&` | binaryOp | 6 |
| `||` | binaryOp | 7 |
| `^` | binaryOp | 8 |
| `in` | binaryOp | 9 |
| `!` | unaryOp | — |
| `.` | dot | — |
| `[` `]` `{` `}` `:` `,` `(` `)` `?` | control | — |

### AST node types (from Parser/Evaluator handlers)
| Node type | Fields | Notes |
|---|---|---|
| `Literal` | `value` | number, string, boolean |
| `Identifier` | `value` | variable name |
| `Variable` | `value` | context lookup |
| `BinaryOp` | `op`, `left`, `right` | |
| `UnaryOp` | `op`, `right` | |
| `Transform` | `name`, `args[]`, `subject` | pipe transforms |
| `Filter` | `expr`, `relative`, `subject` | array filter |
| `Conditional` | `truth`, `consequent`, `alternate` | ternary |
| `ArrayLiteral` | `value[]` | |
| `ObjectLiteral` | `value[]` | key-value pairs |

### Built-in transforms
`lower` / `upper` / `length` / `extract` / `split` / `replace` — each called
as `subject | transformName(args...)`.

---

## 2. Test Fixtures Inventory

### Source: `Jexl/__tests__/lib/` (119 tests total, all passing)

| File | Tests | Coverage |
|---|---|---|
| `Lexer.test.js` | 21 | tokenization: strings, escaping, identifiers, numbers, booleans, operators, control chars, invalid tokens, full expression |
| `Parser.test.js` | 29 | AST construction: all node types, precedence, associativity, transforms, filters, conditionals, arrays, objects |
| `Evaluator.test.js` | 28 | evaluation semantics: arithmetic, comparisons, logical, transforms, filters, conditionals, context vars, async |
| `Jexl.test.js` | 20 | public API: compile, eval, evalSync, addOp, grammar manipulation, error handling |

### Fixture categories for MoonBit parity:
- **Normal cases**: arithmetic expressions, string ops, transforms, filters
- **Boundary cases**: empty strings, nested filters, deeply nested conditionals, chain of transforms
- **Error cases**: invalid tokens, unparseable expressions, undefined variables, type mismatches in eval
- **Async/sync**: `evalSync` must throw if a transform returns a Promise; `eval` must await

---

## 3. JavaScript Semantics Pitfalls (must be preserved or consciously diverged)

### 3.1 `==` loose equality (Jexl uses `==` / `!=` operators)
Jexl's evaluator uses JavaScript's `==` (loose equality), not `===` (strict).
This means:
- `"1" == 1` → **true** (string coerced to number)
- `null == undefined` → **true**
- `0 == false` → **true**
- `"" == false` → **true**

**MoonBit decision**: Preserve Jexl behavior for parity. After parity, a
`strictEquals` mode can be added as an enhancement (matching expr's default).

### 3.2 Prototype chain access
Jexl's evaluator accesses context via `context[val.value]` — JavaScript
property access traverses the prototype chain. A context like `{}` with
`Object.prototype` polluted could expose unexpected keys.

**MoonBit decision**: MoonBit's Map does not have a prototype chain, so this
is inherently safer. No special handling needed — this is a *security
improvement* over Jexl.

### 3.3 PromiseSync recursion (`lib/PromiseSync.js`)
Jexl wraps evaluation in `PromiseSync` to support both sync and async modes.
The sync path manually walks a `Promise`-like structure to extract values
without `await`. If a transform returns an actual `Promise`, `evalSync`
throws `"Cannot eval an async transform in a non-async context"`.

**MoonBit decision**: MoonBit has no Promises. The evaluator will be
synchronous-only initially. Async evaluation (via coroutines or callbacks)
is a future enhancement, not a parity requirement for the base port.

### 3.4 Number coercion
Jexl relies on JavaScript's implicit type coercion:
- `"5" + 3` → `"53"` (string concat)
- `"5" - 3` → `2` (numeric subtraction)
- `"5" * 3` → `15` (numeric multiplication)

**MoonBit decision**: MoonBit is strongly typed. The evaluator will need a
coercion layer to match Jexl's behavior: attempt numeric coercion for `-`,
`*`, `/`, `%` operators when one operand is a string that looks numeric;
concatenate for `+` when either is a string.

### 3.5 Truthiness
JavaScript's falsy values: `false`, `0`, `""`, `null`, `undefined`, `NaN`.
Everything else (including `[]`, `{}`) is truthy.

**MoonBit decision**: Must implement an `is_truthy()` function that mirrors
this exact set, since conditional (`?:`) and logical operators depend on it.

### 3.6 `in` operator
JavaScript's `in` checks property existence: `"foo" in {foo:1}` → true.
For arrays, `0 in [1,2]` → true (index exists).

**MoonBit decision**: Implement `in` for both maps (key exists) and arrays
(index is integer and in bounds).

### 3.7 `undefined` vs `null`
Jexl uses `undefined` for missing variables and `null` for explicit null.
MoonBit's `Option` type maps to this: `None` = undefined, explicit null
needs a nullable wrapper.

**MoonBit decision**: Use `Option[Value]` where `None` represents both
undefined and null (Jexl treats them as equal under `==`).

### 3.8 Whitespace handling in Lexer
Jexl appends trailing whitespace to the *previous* token's `raw` field,
not the next token. This is an observable behavior in the test suite.

### 3.9 Context-dependent minus
A `-` is negate (not subtract) when:
- It's the first token, OR
- The previous token is: `BinaryOp`, `OpenParen`, `Comma`, `Question`, `Colon`,
  `OpenBracket`, `OpenCurl`, `UnaryOp`, `Pipe`

---

## 4. Parity Verification Status

| Layer | JS suite | MoonBit tests | Status |
|---|---|---|---|
| Lexer | `Lexer.test.js` (21) | `lexer_test` (21) | ✅ passing |
| Parser | `Parser.test.js` (29) | `parser_test` (29) | ✅ passing |
| Evaluator | `Evaluator.test.js` (28) | `evaluator_test` (28) | ✅ passing |
| API | `Jexl.test.js` + `Expression.test.js` (20) | `jexl_test` (26) | ✅ passing |
| **Total** | | | **104/104** |

Coverage notes:
- `Expression.test.js` compile-count spy assertions have no MoonBit
  analogue (no method spies); lazy-compile behavior is covered
  behaviorally.
- The `expr\`template\`` API (JS tagged template) is not applicable to
  MoonBit.
- Promise/PromiseSync machinery collapses: MoonBit is synchronous, so
  `eval` and `evalSync` are one operation — the manual-eval (lazy
  operand) operator test proves short-circuit parity instead.

**Cross-validation**: run both Jexl and mbel on the same fixtures and
compare AST/eval outputs for exact match — every ported test case IS
such a fixture, so this is satisfied by the suites above.

### Stage-3 differential results (2026-09-04)

Hand-written corpus (`tools/corpus.txt`): **180/180 identical**.
Generated fuzz (`tools/fuzz1.txt`, seed 42): **1154/1154 identical**.
Generated fuzz (`tools/fuzz.txt`, seed 20260904): **1999/2000 identical**.

Known divergences (all documented):
| # | Case | JS | mbel | Cause |
|---|---|---|---|---|
| 1 | `8 ^ [2.5]` | 181.01933598375618 | 181.01933598375615 | V8 `Math.pow` vs MoonBit pow differ 1 ulp (libm, not logic) |
| 2 | `{a:1} == {a:1}` | false | true | JS object equality is by reference; mbel compares structurally (see §3.1) |
| 3 | async transforms | — | — | JS Promises have no MoonBit counterpart; eval is synchronous |

Numeric-parity fixes this phase discovered: correctly-rounded decimal
literal parsing (integer accumulation, single division); JS relational
compare applies ToPrimitive before the strings-vs-numeric decision;
`%` follows exact fmod semantics via Dekker double-double arithmetic;
string relational comparison is code-unit lexicographic (MoonBit's
`String.compare` is length-first).

---

## 5. ts2moonbit Scope Boundary

The ts2moonbit skill is a *methodology guide* for TypeScript→MoonBit migration.
Jexl is plain JavaScript (not TypeScript), so the skill's TS-specific tooling
(type extraction, interface mapping) doesn't apply directly. However, the
methodology (phase-by-phase porting, parity testing) is still useful as a
process framework.

**What ts2moonbit covers**: reducing the manual effort of translating
imperative JS logic to MoonBit idioms (loops, conditionals, string ops).

**What it does NOT cover**: catching up to expr's capabilities (type checker,
bytecode VM, optimizer, 70+ built-in functions) — those are ~15,000 lines of
new development, not a migration task.
