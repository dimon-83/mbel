# Proposal: write-path integration findings and a narrowly scoped host-builtin channel

- **Status:** Draft — revised 2026-11-03 per `docs/proposals/0002-review-2026-11-03.md` (all 8 must-fixes applied; see `docs/proposals/0002-implementation-plan-2026-11-03.md` §P0). Rulings same day: Decision 4 = (a) ((d1) input integer-exactness landed in mbel [Unreleased], bound ±(2^53 − 1)); Decision 3 = (i) ((d2) divide-by-zero error **declined** — `/` keeps +Inf and expr parity; the modu `y != 0` guard becomes a permanent discipline)
- **Date:** 2026-11-03
- **Target:** 0.4.x (M2 only, gated on a mooncry spike; M0/M1 are modu-side and version-independent; M3 is re-based — (d1) landed as of [Unreleased], (d2) declined per Decision 3 = (i), hybrid decimal deferred behind a named trigger)
- **Author:** external embedder (modu integration)
- **Related:** `docs/proposals/0001-user-functions-for-embedders.md` (P4 strict registration, P5 error codes, non-goals on host callbacks), `docs/proposals/0002-review-2026-11-03.md` (source of the revisions), `engine/userfuncs.mbt`, `playground/web/web.mbt`, `builtin/builtin.mbt`, modu `packages/core/src/mbel/` (kernel/bridge/functions/errorCodes), modu `packages/core/src/logic/` (types/command/validate)

## TL;DR

modu is spec-izing its system administration logic (users, roles, dictionaries,
menus) into a command pipeline whose validate/decide/compute slots evaluate MBEL
expressions. A source-level review — prompted by a black-box probe of the
vendored 0.3.7+M1 artifact — found four integration gaps. Verdict up front:

1. **Only one gap is language-by-design:** function names are single-token
   identifiers (`engine/userfuncs.mbt:52` mirrors the expr lexer; `a.b` is
   always member access). A dotted `$host.hashPassword` namespace is not a
   missing feature; it is a lexical decision we should not fight.
2. The other three (host-native functions, shadowing governance, error
   positions) are **unired export/binding layers**, not language work — and two
   of them are already on this repo's roadmap as 0001 P4/P5.
3. **modu's decision (D3) is therefore unchanged and unblocked:** the write
   path proceeds with a *host step* at the command-slot layer (M1), which keeps
   hashing out of the expression language entirely. modu does not wait for
   0.4.
4. The one genuinely new ask here is **M2**: an optional, narrowly scoped
   `$host(name, args_json)` reserved builtin backed by a wasm import — in
   deliberate tension with 0001's "no host callbacks" non-goal, argued below,
   and recommended *against* for anything modu's invariants depend on. M2 is
   **gated on a mooncry spike** (§5): a pure-MoonBit crypto library now exists
   on mooncakes; if it covers argon2id, a wasm-native builtin serves the write
   path with no import channel at all.
5. The numeric gap is recorded, re-based per review (M3): the loss point is
   **not** the value model — `Value` carries `NumVal(Double)` *and*
   `IntVal(Int64)`; integers are first-class in the expr dialect — but the
   **JSON input boundary**, which double-mapped every incoming env number
   (`json_to_value`; the output side is already exact — `to_json_string` /
   `canon` serialize `IntVal` with exact int64 digits, and a spike found the
   "documented divergence" comment in `value_to_json` to be dead code).
   Rulings (2026-11-03): (d1) integer-exact JSON input **landed** in mbel
   [Unreleased] (Decision 4 = (a): integer-valued numbers within ±(2^53 − 1)
   become `IntVal`; `5.0` maps like `5`); (d2) divide-by-zero error
   **declined** (Decision 3 = (i): `/` keeps `+Inf` and expr parity — today
   `x/y > 0.5` with `y == 0` remains **true**, so modu's `y != 0` guard is a
   permanent discipline); hybrid decimal stays deferred behind a named
   trigger. modu works around the residual float territory by discipline
   (money in minor integer units) plus **mandatory** schema-aware lint — the
   checker is env-blind, so host-side lint is the only enforcement point in
   every world.

## 1. Capability inventory (source evidence)

What the source review confirmed, aligned against what modu's write path needs.

| Capability | Evidence | modu write-path usage |
| --- | --- | --- |
| Typed standard dialect + legacy Jexl dialect; tree-walk and VM engines | `playground/web/web.mbt:85` (`eval_jexl`), `:51` (engine select) | standard dialect, walk engine — locked |
| `let` / `if` / ternary / `??` / pipes / relative filters / ranges | keyword table `engine/userfuncs.mbt:29` (`let`, `if`, `else` reserved) | judge rules, controlled reads |
| Resource budgets: maxNodes 10k, maxDepth 10k, maxSteps 1M, userfnDepth 256 | `playground/web/web.mbt:34` (`describe_abi` limits) | DoS guard already built in |
| User functions: JSON defs, auto-extracted params, forward refs/recursion, **checked registration with body type checks and arity checks** (0001 P2, landed in [Unreleased]) | `engine/userfuncs.mbt:4`; CHANGELOG [Unreleased] "Checked user-function registration (P2)" | `functions.json` channel, already in use |
| Reserved-name mechanism exists: keywords, `$env`, aggregates | `engine/userfuncs.mbt:81-96` (`validate_userfn_name`) | the seam M2 would extend |
| Native-closure registration exists at the engine layer (`add_transform`, `upsert_fn` into `grammar.functions`) | `playground/web/web.mbt:62-81`; `engine/engine.mbt:64-72` | proves dispatch architecture; no JS callback crosses the wasm boundary today |
| Strings: `upper`/`lower` are **ASCII-only**; split/join; RE2 `matches`; base64 (UTF-8) | `builtin/strutil.mbt:1`; `builtin/base64.mbt:71` | username/role-code format rules — sufficient; non-ASCII case mapping unavailable (no current need) |
| Time: int64 nanoseconds, UTC only; `now()` via `__moonbit_time_unstable.now` import | `builtin/time.mbt:5` | audited timestamps; the sole existing wasm import — M2's feasibility precedent |
| Two-type numeric runtime: `Value` carries `NumVal(Double)` **and** `IntVal(Int64)` — expr-dialect integer literals and pure-integer arithmetic stay `IntVal` (Int64 wrap, Go semantics, `evaluator/evaluator.mbt:390-393`); int∘float promotes to double (`:395-398`); `sum` over all-int input stays `IntVal` (`evaluator/aggregates.mbt:105-127`); bitwise range-checks via Int64 and returns `IntVal` (`builtin/bitwise.mbt:27-33`) — one of several Int64 paths, not the only round-trip | `ast/ast.mbt:28-48`; `evaluator/evaluator.mbt:389-398` | literal-derivation integer arithmetic is exact; env-sourced integers lose integer-ness at the JSON boundary (see M3) |
| Error positions: parse errors carry line:col (`ParseErrExpr(msg, line, col)` → `parse error at L:C`); checked mode reports `(L:C)` and per-function body positions | `playground/web/web.mbt:129-142`; CHANGELOG [Unreleased] | **exists but modu does not surface it** (M0-1) |

Alignment summary against modu's needs:

| modu write-path need | Status |
| --- | --- |
| Judge rules, comparisons, aggregates, format validation (RE2) | covered today |
| Password strength validation in a `validate` slot | covered today (`matches`) |
| Argon2id hashing in a `compute` slot | **impossible**: no native channel; functions bodies are MBEL source only; no crypto builtins (base64 is encoding, not crypto) |
| Project functions must not shadow platform-relied-upon builtins | **partially possible**: pool upsert makes shadowing a designed feature; probe showed `upper` shadowable, `len` not (standard-dialect special path, `builtin/builtin.mbt:617`) |
| Determinism ("same rule, same verdict, every machine" — modu's hard contract) | intact while expressions stay pure; M2 would put a named hole in it |
| Data-type discipline (e.g. "decimal column accumulated as double") | **not enforceable in the language, ever**: the checker is env-blind — env/member reads are `UnknownN` (`expr/check.mbt:11-15`, `:235-238`) and `CheckCtx` has no column-type channel (`:115-124`) | host-side schema-aware lint is the **only** enforcement point (see M0 item 3, M3) |

## 2. Gap list with cause attribution

| # | Gap | Cause layer | Verdict |
| --- | --- | --- | --- |
| 1 | Dotted function names (`$host.hashPassword`) rejected | **Language semantics** (by design) | Do not change. Single-token names; `$` is a legal identifier char (`engine/userfuncs.mbt:52-60`), so single-token `$hash_password` works end-to-end through `describe_functions`/`eval_with_functions` (probe-verified) |
| 2 | No host-native function injection | **Host binding + export layer** — engine has native-closure dispatch (`add_transform`); missing is a wasm import callback and one registration | Solvable with an ABI addition, no language change (M2) — but see the tension with 0001 |
| 3 | Shadowing governance incomplete | **Language semantics choice** + **export-layer gap** — shadowing is a feature ("extend an instance without writing MoonBit", `engine/userfuncs.mbt:4`); the reserved list just isn't exhaustive, and hosts can't fetch the builtin name set | Already proposed as 0001 **P4** (strict mode); modu-side stopgap M0-2 until then |
| 4 | Error positions not surfaced | **Export layer** — positions exist in parse/check messages; `$error` is a plain-text envelope | modu-side fix with zero wasm changes (M0-1); improves further with 0001 **P5** ($code) |
| 5 | No arbitrary precision; the JSON **input** boundary double-maps env numbers | **Boundary layer** — `Value` carries `NumVal(Double)` *and* `IntVal(Int64)` (`ast/ast.mbt:28-48`); the dominant loss is at JSON input: `json_to_value` maps every JSON number to `NumVal` (`playground/web/web.mbt:159`, `cmd/main/main.mbt:86`, `builtin/helpers.mbt:227` — three synced copies). Output is already exact (`to_json_string`, `builtin/helpers.mbt:448`; `canon` in web/main) | Cheap 0.4 item (d1): integer-exact JSON input; hybrid decimal deferred behind a named trigger (M3); modu discipline in the meantime |
| 6 | Division by zero silently yields ±Inf — `x / y > 0.5` with `y == 0` evaluates **true** | **Language semantics** — `/` is always float division, no divide-by-zero error (`evaluator/evaluator.mbt:447-454`) | **Declined (Decision 3 = (i), 2026-11-03):** `/` keeps +Inf and expr parity (existing dual-engine anchors and the Jexl corpus lock `1/0 = +Inf`); modu rule-writing mandates explicit `y != 0` guards as a **permanent** discipline, enforced by modu's schema-aware lint |

## 3. M0 — modu-side, zero wasm cost (do now, inside P4)

None of the items below touches this repo; all are recorded so the retirement
conditions are explicit.

1. **Error-position passthrough.** modu `packages/core/src/mbel/errorCodes.ts`
   currently maps `$error` messages by substring. Add parsers for the
   `"parse error at L:C: msg"` and `"... (L:C)"` shapes and carry a position
   into the validation issue (modu `logic/validate.ts` already has an `at`
   convention from `batch.shape`). **Compile-mode check errors are
   multi-line:** the message is `msg (L:C)` followed by a source line and a
   caret block (`\n | src-line\n | ...^`, `expr/eval.mbt:147-168`,
   `positioned()`) — the parsers must strip or carry the multi-line form, or
   every mapped message embeds source text. Result: `modu check` reports
   that point at rows and columns today, using what the parse/check layers
   already emit.
2. **Builtin reserved-name stopgap.** modu
   `packages/core/src/mbel/functions.ts` hardcodes the builtin name list
   (maintained alongside its conformance corpus per its vendoring discipline)
   and rejects project functions that collide, failing into the existing
   `validateBundle` → `modu check` path. **Retire when 0001 P4 lands** (strict
   mode puts enforcement here, in the engine, where it belongs) — or earlier,
   if a builtin-name manifest ships (see Open questions 3).
3. **Schema-aware numeric lint (the enforcement point).** The checker inside
   mbel is structurally env-blind — env/member reads are `UnknownN`
   (`expr/check.mbt:11-15`, `:235-238`), and `CheckCtx` carries function
   arities and callable names only, no column-type channel (`:115-124`) — so
   *no* language-side check, now or after any M3 outcome, can catch "decimal
   column accumulated as double" or an unguarded division. modu's TS-side
   `validate` should warn/error when expressions use `sum`/`avg`/`**`/`/`
   over decimal-typed columns, or `==` on computed floats. **This lint is the
   mechanism itself, not an optional aid** — it stays mandatory in every
   world (see M3).

## 4. M1 — modu host step (a decision recorded for context, not a request)

modu's command pipeline adds a platform-only slot-step variant:

```jsonc
{ "host": "hashPassword", "with": { /* refs */ }, "into": "passwordHash" }
```

executed by the TypeScript command executor against a hardcoded
`HOST_FUNCTIONS` whitelist (argon2id first). Project-authored files that
contain a `host:` step are rejected by `validate`.

Why this is the right cut, and why it does not need this repo:

- **Structural collision-proofing:** host functions live in the slot-step
  namespace; project rules/functions live in the MBEL namespace. The two
  never share a lookup table, so no naming discipline is required.
- **Determinism is preserved where it matters:** invariants (LAST_ADMIN,
  password policy, audit) never become host-dependent expressions. modu's
  contract "same rule, same verdict, every machine" stays unbroken.
- **No version dependency:** works against the current 0.3.7+M1 artifact
  unchanged.

## 5. M2 — optional 0.4 import channel (the actual ask)

### Relationship to 0001's non-goals

0001 §3 lists "Host callbacks / FFI / reflection" as a non-goal; §7 is the
directive ("Do not add host callbacks to the wasm ABI"); and the three-part
objection — callbacks "break the pure sandbox, are not portable to wasm, and
make results non-deterministic across hosts" — is 0001 **§9 (Alternatives)**,
not §7. Two of those three objections applied to *user-defined
functions* calling out — this proposal keeps that prohibition intact. The
wasm-portability objection no longer applies (the artifact is wasm-only and
already imports `__moonbit_time_unstable.now`). The determinism objection is
the core one — and rather than argue it down, M2 adopts a precondition that
discharges it **structurally**: strict-pure checked mode (below).

What is proposed is a single, reserved, platform-facing builtin:

- Name: `$host(name, args_json) -> json`. Reserved in
  `validate_userfn_name` next to `$env` (`engine/userfuncs.mbt:88`) — one
  added line, existing mechanism.
- Implementation: a wasm-gc import `__modu_host.host_call(name, args_json)`,
  declared extern in MoonBit (the `__moonbit_time_unstable.now` import in
  `builtin/time.mbt` is the working precedent for the extern form), wrapped as
  a native builtin registered into the pool the way demo transforms are
  (`playground/web/web.mbt:62`).
- Marshalling: args as canonical JSON string in, canonical JSON string out;
  host-side failures return `{"$error": ...}` and propagate as normal
  evaluation errors.

### Precondition: strict-pure by default (condition of acceptance, not an enhancement)

M2 is proposed *only together with* this change; it is the precondition of the
proposal being accepted, not an optional hardening added on:

- In checked mode, `$host` is **rejected by default** — reported the same way as
  any unknown name.
- The only way to enable `$host` is an explicit opt-in at engine load time,
  supplied by the host — in modu's case, the platform base bundle's own
  registration. A functions file, rules file, or any project-authored input can
  never set it.
- Unchecked evaluation (`eval_expr`) keeps current semantics; the flag guards
  exactly the path that `modu check` and the write pipeline rely on.

Why this is the precondition: 0001's core objection to host callbacks is that
results become "non-deterministic across hosts." With strict-pure default,
every expression checked mode accepts is deterministic **by construction** —
`$host` can only appear where a platform explicitly took responsibility for
it, and modu takes that responsibility only in presentation-adjacent
expressions, never in invariant-bearing rules. The objection is eliminated by
the shape of the design, not out-argued.

### Gate: mooncry spike first (P1)

**Gate status (2026-11-03, spike executed): 可直接用.** `mooncry@0.95.0`
(mooncakes, released 2026-09-20) exposes native `argon2id(password, salt,
t_cost, m_cost, parallelism, hash_len)` (`lib/argon2.mbt:524`, RFC 9106
2d/2i/2id; the library's vectors are cross-checked against argon2-cffi, the
reference C implementation); constant-time verify composes trivially as
`argon2id` + `bytes_equal` (`lib/crypto.mbt:85`). Purity: zero dependencies,
no FFI (`moon.mod`). License: Apache-2.0. Scratch-spike evidence: the
library's own argon2id vector reproduced, and a hash/verify round-trip
(OWASP-ish t=3, m=19456 KiB, p=2, hlen=32) passed with correct/wrong
passwords discriminated. **For hashing, M2 thereby loses its necessity** —
a wasm-native `$hash_password`-style builtin built on mooncry needs no import
channel, no host stubs, and no determinism carve-out; M2's residual value is
the presentation-adjacent conveniences below only. Caveats to carry into any
builtin PR: mooncry is self-tested but not formally audited, and m_cost is
wasm linear memory (budget via `describe_abi.limits`, same slot as the
`hostCalls` question in Open questions 2).

Verdict criteria (frozen in `docs/proposals/0002-implementation-plan-2026-11-03.md`
§P1): coverage, purity, maintenance, license — all four pass. Consequence for
M2's disposition: a wasm-native `$hash_password`-style builtin built on
mooncry serves modu's write path with **no import channel, no host stubs, no
determinism carve-out**; M2's residual ask is the presentation-adjacent
conveniences below, to be weighed against 0001's non-goal on their own
(merit, not necessity. Default posture per the implementation plan: not
pursued unless modu still wants expression-level host calls).

### What it buys

Pure-but-host-provided conveniences at the *expression* layer: `uuid()`,
`random_int(a,b)`, host-configured locale casing — capabilities a platform may
accept host-dependence for, in expressions that are presentation-adjacent
rather than invariant-bearing. Heavy or security-sensitive work (argon2)
stays in slot steps even after M2.

### File-level changes

| File | Change |
| --- | --- |
| `playground/web/web.mbt` | extern declaration for the import; register `$host` as a builtin; add to `describe_abi` exports note and `limits` (see Open questions 2) |
| `engine/userfuncs.mbt` | reserve the name `$host` in `validate_userfn_name` |
| `engine/exprapi.mbt` | **zero checker changes needed**: `strict_calls` already rejects any callee outside `functions`/`callables`/aggregates (`expr/check.mbt:296-298`, mechanism at `:156-160`), and the instance checked entry threads `callables` from the engine (`expr/eval.mbt:74-105`, assembled at `engine/exprapi.mbt:97`). The real surface: register `$host` into the instance pool **only under the load-time opt-in**, and thread it into `callables` there — the flag is host-supplied and never settable from functions/rules files (the Precondition above) |
| `playground/mbel.abi.json` | add the import to the manifest; `tools/check_abi.mjs` already enforces manifest/artifact equality in CI |
| Host stubs | `cmd/main` and test hosts must stub `__modu_host.host_call` (fail-closed: return a structured error) so non-modu hosts keep working |

### Cost

- Version: **0.4.0** (additive export/import, minor bump), rebuilt artifact,
  new sha256; conformance corpus gains `$host` anchors; checked mode's
  unknown-name/arity checks apply to `$host` like any other call — and without
  the opt-in flag, `$host` is simply an unknown name (0001 P2 makes both
  behaviors automatic).
- Risk: one **~30-minute spike** to pin the exact MoonBit extern form for a
  wasm-gc import (copy the time-import pattern; verify import modularity).
- Sequencing note: modu consumes 0.4 only for *optional* expression-layer
  conveniences. If M2 is rejected, nothing in modu breaks.

## 6. M3 — decimal: gap re-located to the JSON boundary; cheap 0.4 items pulled out; hybrid decimal deferred with a named trigger

*(Re-based per `0002-review-2026-11-03.md` must-fixes #1/#2/#3/#4/#8. The
earlier draft recorded this gap as "no decimal type — `NumVal` is a double,
bitwise is the only Int64 round-trip, long-term non-goal"; that was factually
wrong in three places and disposed of the wrong thing.)*

### The verified value model

`Value` carries both `NumVal(Double)` and `IntVal(Int64)` (`ast/ast.mbt:28-48`).
In the expr dialect, integer literals and pure-integer arithmetic stay
`IntVal` — exact, with silent Int64 wrap on overflow (Go semantics,
`evaluator/evaluator.mbt:390-393`); int∘float promotes to double (`:395-398`);
`sum` over all-int input stays `IntVal` (`evaluator/aggregates.mbt:105-127`);
bitwise returns `IntVal` (`builtin/bitwise.mbt:27-33`). Int64 is first-class in
the expr dialect. What does **not** exist is arbitrary precision — 2^63 is the
ceiling — but "no bigint" is not the loss point for env data.

### Where exactness actually dies: the JSON input boundary

| Stage | Representation | Exact? |
| --- | --- | --- |
| Integer literal (expr) / pure-integer arithmetic / bitwise / `sum` over ints | `IntVal(Int64)` | exact (silent wrap on overflow) |
| int ∘ float | promotes to `NumVal(Double)` | double semantics |
| **JSON in (env)** — `json_to_value` maps every JSON number to `NumVal` (`playground/web/web.mbt:159`, `cmd/main/main.mbt:86`, `builtin/helpers.mbt:227`) | `NumVal` | **dies here for env data**; core's JSON lexer keeps integers ≤ 2^53 exact, mbel discards the integer-ness |
| JSON out — `to_json_string` (`builtin/helpers.mbt:448`) and `canon` (web/main) | exact int64 digits | exact (already landed; the old `value_to_json` `to_double()` path was dead code — removed) |
| `/` and `**` | always float (`expr/check.mbt:569-575`, `:625-631`) | float; `1/0 = +Inf` |
| `mean`/`median` | double (`builtin/builtin.mbt:111-139`) | double |

Env-sourced integers never get integer treatment at all — the leak is the
input direction alone. (Implementation spike, 2026-11-03: core's JSON lexer
sets the number's raw-representation component only when the value cannot
round-trip as a double — small integers carry none — so distinguishing `5`
from `5.0` at the input boundary requires an `is_integer`-style heuristic,
which is the plan's Decision 4; see `0002-implementation-plan-2026-11-03.md`.)

### The missed hazard: division by zero is silent ±Inf

`/` is always float division with no divide-by-zero error
(`evaluator/evaluator.mbt:447-454`): a ratio-style judge rule
`x / y > 0.5` with `y == 0` evaluates **true**. For a write-path rule engine
this is a correctness hazard, independent of the decimal question (gap 6).
(`%` already errors on a zero `IntVal` divisor — `evaluator.mbt:464-470` —
so the gap is `/` alone.)

### Why no language-side typing can police this (checker env-blindness)

The checker's own scope note: env values, dynamic members and heterogeneous
containers stay unknown (`expr/check.mbt:11-15`); `EMember` is unconditionally
`UnknownN` (`:235-238`); `CheckCtx` carries function arities and callable names
only — no column-type channel (`:115-124`). **Host-side schema-aware lint is
the only enforcement point in every world**: "this decimal column is being
double-accumulated" is unenforceable in the language, with or without a
decimal Nature. M0 item 3's TS warning is the mechanism, not an optional aid.

### Disposition

1. **modu now — (a) discipline + mandatory schema-aware lint:** money enters
   expressions as **minor integer units** ≤ 2^53 (doubles are exact there);
   lint warns on `sum`/`avg`/`**`/`/` over decimal-typed columns and on `==`
   over computed floats; rule-writing rules mandate the divide guard
   (`y != 0`) and deliberate rounding. Days of host work, zero wasm risk.
2. **(d1) integer-exact JSON input — landed in mbel [Unreleased] (Decision 4 =
   (a), 2026-11-03):** `json_to_value` (three synced copies: web, cmd/main,
   builtin — the `fromJSON` builtin inherits the fix for free) maps
   integer-valued JSON numbers within **±(2^53 − 1)** to `IntVal`; `5` and
   `5.0` are indistinguishable at the Json layer and both become `IntVal`.
   The bound is 2^53 − 1, not 2^53: integer literals at or beyond 2^53
   arrive as `Number(double, repr~Some(_))` where the double already aliases
   neighbors (2^53 + 1 parses to the same double as 2^53), so mapping them
   would claim false exactness — they stay `NumVal` (exact repr-based int64
   mapping is future work). The output side is already exact
   (`to_json_string` + `canon`). Legacy-dialect note: an `IntVal` operand
   takes the typed operator path, so `"x" + n` over an integer env value is
   a type error instead of concatenation (CHANGELOG records this).
3. **(d2) divide-by-zero error — declined (Decision 3 = (i), 2026-11-03):**
   `/` keeps +Inf everywhere. The pre-check found `1/0 = +Inf` is already a
   dual-engine parity anchor (`typed_test.mbt:60`, `vm_parity_test.mbt:92`)
   and Jexl-corpus-locked; changing it is a parity-contract break bought for
   a loudness the modu lint can deliver host-side. Consequence: the divide
   guard (`y != 0`) in modu's rule-writing rules is a **permanent**
   discipline, not a stopgap.
4. **Deferred behind a named trigger — (c) hybrid decimal:** ship only when
   **all three** business signals fire: a modu vertical needs fractional
   money math (rates/tax/FX) *inside judge rules*, AND a differential test
   fails reproducibly under double, AND the requirement is exactness (not
   precautionary). Design sketch, if triggered: a `DecVal` variant reusing
   `moonbitlang/x/decimal` (mooncakes: arbitrary precision, `max_scale = 28`)
   instead of hand-rolling; boundary protocol = decimal columns cross the
   JSON boundary **as strings** + an explicit `dec("12.30")` / `dec($in.col)`
   parse — opt-in per expression; decimal∘decimal exact; decimal mixed with
   float/NumVal is a compile+runtime error (forces the discipline); `sum`
   gains a decimal accumulator; output via the (d1) typed writer; **no**
   checker `Nature::DecN` initially. Budget as a focused release, not a
   patch.
5. **(b) full checker-typed decimal stays a non-goal:** static scale is
   nearly pointless while env reads are `UnknownN` — the checker would only
   ever type literals; same blind spot, much more machinery.

And the explicit caveat: **language-side decimal does not solve modu's
governance problem.** The `dec()`-wrap boundary protocol is enforceable only
host-side (modu lint requires the wrap on decimal-typed columns); the
governance cost never moves from host to language.

## 7. Compatibility and upgrade sequencing

- **In-place upgrade, no dual-version coexistence.** modu's vendoring rule is
  "new version = new filename + new sha256 + full verify-logic regression";
  the old artifact is deleted on swap.
- The current vendored artifact (0.3.7 + the three function exports, 574,923 B)
  **predates** the landed [Unreleased] work (ABI manifest, checked
  registration). The next swap — whether 0.4 or an interim 0.3.8 — picks up
  `describe_abi`, checked registration, and `$code` errors together; modu then
  retires M0-2 (strict mode replaces the hardcoded list) and re-anchors
  conformance.
- Order of operations: mbel release → single modu PR (swap wasm, update
  kernel sha256, adopt strict mode, add conformance anchors) → green
  `verify:logic`. No parallel old/new consumption.

## 8. Impact on modu's D3 / P4

- **D3 stays a host-step design (M1).** The source review strengthens the
  earlier probe-based verdict: the dotted-namespace idea dies at the lexical
  layer (by design), and the import channel, while cheap, must not gate the
  write path.
- **P4 scope unchanged, risk reduced.** No mbel dependency means P4 does not
  inherit the largest regression surface (wasm version swap). M0-1 gives
  `modu check` positioned override reports — better governance UX than
  originally planned, at zero cost here.
- Discipline items land in modu's rule-writing rules (M3 re-based):
  minor-integer-unit money, explicit divide guards (`y != 0`) — **permanent**
  per Decision 3 = (i), no `==` on computed floats — enforced by modu's
  schema-aware lint (M0 item 3), the **only** enforcement point given
  checker env-blindness. (d1) is in mbel [Unreleased] and picked up at the
  next vendor swap; (d2) was declined and never ships. Neither gates P4.

## 9. Open questions

1. **Extern spike (M2 blocker):** the exact MoonBit `extern` form for a
   user-defined wasm-gc import — the `__moonbit_time_unstable.now` pattern is
   the template; ~30 minutes to verify, including import modularity (can the
   import be declared so hosts without it still instantiate, or are stubs
   mandatory?).
2. **Budgeting `$host`:** should host calls count against `maxSteps` (they
   can), and should `describe_abi.limits` carry a `hostCalls` cap so a
   pathological expression cannot ping-pong the boundary unbounded?
3. **Builtin-name manifest:** if 0001 P4 strict mode is the retirement
   condition for M0-2, should `describe_abi` also expose the builtin name set
   (or a `describe_builtins()` export) so hosts can *report* the conflict
   surface even in non-strict mode? P4 makes enforcement the engine's job;
   discovery is still the host's.
4. **Shadowing asymmetry documentation:** `upper` is shadowable, `len` is not
   (standard-dialect special path, `builtin/builtin.mbt:617`). P4 makes the
   asymmetry moot, but until then it is undocumented dialect behavior worth a
   line in `docs/en/functions.md`.
5. **Strict-pure flag — absorbed into §5.** Originally asked whether checked
   mode should optionally reject `$host` outright; this is now M2's
   **precondition** (checked mode rejects `$host` by default; enabling is a
   host-level opt-in at engine load, never settable from project files). What
   remains after absorption is documentation only: if M2 lands,
   `docs/en/functions.md` must state that `$host` results sit outside the
   determinism guarantee and that invariant-bearing rules must not call it.
6. **Ecosystem check (recorded per review must-fix #8):** mooncakes now
   carries `moonbitlang/x/decimal` (arbitrary precision, `max_scale = 28`) —
   the reuse candidate for M3's deferred (c) option — and `mooncry`
   (pure-MoonBit, zero-dependency, test-vector-verified crypto), which is
   now M2's first gate (§5). Neither was surveyed when 0002 was first
   drafted; both re-base the cost estimates of M3(c) and M2 respectively.

## Appendix A — probe evidence (vendored 0.3.7+M1 artifact, Node 24, js-string builtins)

Run directly against the vendored wasm, 2026-11-03, before the source review:

| Probe | Result |
| --- | --- |
| `eval_expr("$x", {"x":1})` | `UNDEF` — parses as a single identifier `$x`; not a syntax error (control: `1 +` → `EXPR_SYNTAX`) |
| `eval_expr("$x + 1", {"x":1})` | `"invalid operation: nil + int"` — parsed, name unresolved; `$` is a legal identifier char |
| `dump_ast("$host.hashPassword('a')")` | `call(member(id:$host.hashPassword),str:a)` — dotted callee is member access, never a function name |
| `describe_functions(name:"$host.hashPassword")` | `$error: invalid function name` |
| `describe_functions` + call: `$hash_password('x')` | registered and evaluated end-to-end (single token with `$` works) |
| project function `upper → 42`, then `upper('ab')` | `42` — pool builtin shadowable |
| project function `len → ...`, then `len('abc')` | `3` — not shadowed (special path) |

Note (post-review): the `"invalid operation: nil + int"` probe message is the
typed standard dialect at work — `Value` carries `NumVal(Double)` and
`IntVal(Int64)` as distinct runtime types (`ast/ast.mbt:28-48`); see §1 and
M3 for the corrected numeric model.

## Appendix B — decision ledger (modu side, for cross-reference)

| Decision | Outcome |
| --- | --- |
| D3 (host functions) | **M1 host step**; M2 optional, never load-bearing for invariants |
| D4 (omit semantics for "blank password = don't update") | unchanged by this review; slot-layer concern |
| P4 dependency on mbel | none; M0 items are TS-only and ship inside P4 |
