# Implementation plan from review 0002-review-2026-11-03

- **Status:** Draft — pending decision points in §Decision points
- **Date:** 2026-11-03
- **Author:** mbel maintainer side
- **Related:** `docs/proposals/0002-modu-host-import.md` (subject), `docs/proposals/0002-review-2026-11-03.md` (source of verdicts), `docs/proposals/0001-user-functions-for-embedders.md` (P4/P5 dependencies)
- **Scope:** everything below derived from the review's must-fix list and Part-2 ordering. No source changes are authorized by this document; P0's rewrites land only after approval.

## Dependency graph at a glance

```
P0 (0002 revision, docs)  ──┐
P1 (mooncry spike)         ─┼── all independent, all startable now
P2b (typed JSON writer)    ─┘
P2a (integer-exact input)  ── after Decision 4/5
P3 (divide-by-zero)        ── after Decision 3
P4 (decimal design note)   ── after Decision 1 (folds into P0's M3 rewrite)
P5 (modu handoff doc)      ── after P0/P3 decision (lives in modu repo)
0.4 release                ── bundles P2a/P2b/P3 (+0001 P4 if Decision 6)
```

**Blocking modu P4:** nothing in P0–P4 blocks modu's write path (it runs on
the current 0.3.7+M1 vendor artifact and M1's host step). The only modu-P4
blocker identified by the review lives *inside* modu P4 itself: the
schema-aware lint (P5-1) is a must-do acceptance item of that phase, not a
prerequisite.

---

## P0 — Apply the review's must-fixes to 0002 (documentation PR)

**One PR, docs only.** Blocks: 0002 acceptance. Does **not** block modu P4.

| # | Target section(s) | Rewrite point |
| --- | --- | --- |
| 1 | §1 capability table, §2 gap 5, M3, Appendix A | Two-type runtime: `Value` carries `NumVal(Double)` **and** `IntVal(Int64)` (`ast/ast.mbt:28-48`); expr-dialect integer literals and pure-integer arithmetic stay `IntVal` (Int64 wrap, Go semantics, `evaluator/evaluator.mbt:390-393`); int∘float promotes (`:395-398`); bitwise returns `IntVal` (`builtin/bitwise.mbt:27-33`). Replace "no bigint" with "no arbitrary precision; Int64 is first-class in the expr dialect" |
| 2 | M3 (re-base) | Gap relocated to the **JSON boundary**: input maps every JSON number to `NumVal` (`playground/web/web.mbt:159`), output converts `IntVal` via `to_double()` — in-source "documented divergence until a typed JSON writer" (`builtin/helpers.mbt:189-200`); secondary: `/` and `**` always float (`expr/check.mbt:569-575`, `:625-631`), `mean`/`median` double (`builtin/builtin.mbt:111-139`). Insert the review's loss-point table verbatim |
| 3 | §2 gap list | Add: division by zero silently yields ±Inf (`evaluator/evaluator.mbt:447-454`); `x/y > 0.5` with `y == 0` evaluates **true** — correctness hazard for judge rules |
| 4 | §1, M0, M3 | State checker env-blindness as the structural fact: env/member reads are `UnknownN` (`expr/check.mbt:11-15`, `:235-238`); `sum` checks container-ness only (`:493-520`); `CheckCtx` has no column-type channel (`:115-124`). Corollary in bold: **host-side schema-aware lint is the only enforcement point in every world** — M0's TS warning is the mechanism, not an optional aid |
| 5 | §5 opening | Citation fix: the three-part objection ("pure sandbox / wasm portability / non-determinism") is 0001 **§9 (Alternatives)**; §7 is the directive; §3 the non-goal list |
| 6 | M0-1 | Compile-mode errors append a source line + caret block (`expr/eval.mbt:147-168`, `positioned()`); modu's message parsing must strip or carry the multi-line form |
| 7 | §5 M2 file table | Replace the `expr/check.mbt` row: the precondition needs **zero** checker changes — `strict_calls` already rejects non-callables (`expr/check.mbt:156-160`, `:296-298`), `callables` threads from the engine (`expr/eval.mbt:74-105`, assembled at `engine/exprapi.mbt:97`). Real surface: `$host` pool registration under a load-time opt-in (engine) + `callables` assembly + the existing `engine/userfuncs.mbt:81-96` reservation |
| 8 | §5 gate + M3 + open questions | Add the mooncry gate (see P1) and record `moonbitlang/x/decimal` (mooncakes, `max_scale = 28`) as the reuse candidate for the deferred (c)-option |

- **Acceptance:** diff re-checked against the review's must-fix list — all 8 covered; TL;DR and §8 (D3/P4 impact) updated for consistency with the revised M3/M2; `git diff --stat` touches only `docs/proposals/0002-*.md`.
- **Depends on:** nothing. Fully parallel with P1/P2b.
- **Effort:** 1 人日.
- **Risk / rollback:** doc-only; revert. Main risk is internal inconsistency (TL;DR vs body) — mitigate with the checklist above.

## P1 — mooncry KDF spike (scratch project + small docs PR)

**Blocks:** M2 立项 (not modu P4 — M1's host step stands regardless). If the
verdict is 可直接用, modu P4 *may* choose to swap M1 for a wasm-native builtin;
that is an option, not a dependency.

- **Goal:** decide whether `mooncry` (mooncakes, pure-MoonBit crypto) can host
  argon2id natively, before M2's import channel is pursued at all.
- **Method:** throwaway MoonBit project outside this repo (`moon new` in a
  scratch dir; nothing lands in mbel); add mooncry; exercise hash + verify
  against the library's own vectors (or RFC 9106 vectors).
- **Verdict criteria (frozen):**
  1. **Coverage:** argon2id *generate* and *verify* (constant-time) exist or
     are trivially composable — blake2b-only does **not** count as 可直接用;
  2. **Purity:** zero FFI, zero non-MoonBit deps (read its moon.mod);
  3. **Maintenance:** a release within the last ~6 months and test-vector
     verification claimed in docs;
  4. **License:** Apache-2.0/MIT (compatible with this repo).
- **Allowed conclusions (exactly one):** 可直接用 / 需自建 / 不可用 — plus one
  mandatory sentence: whether M2 thereby loses its necessity (for hashing:
  yes/partial/no). 需自建 means the primitives are sound but argon2id must be
  built on top (blake2b present, KDF absent).
- **Deliverable / PR:** a short gate-status paragraph for 0002 §5 (or the
  review file's appendix) recording verdict + evidence links; ~10 lines of
  docs.
- **Acceptance:** scratch run reproduces the library's argon2 vectors (or
  documents their absence); the verdict sentence exists and matches one of the
  three allowed values.
- **Depends on:** nothing.
- **Effort:** 0.5 人日.
- **Risk / rollback:** none to this repo (scratch project). If 不可用, M2
  remains as designed with its strict-pure precondition.

## P2 — 0.4 cheap item A: integer-exact JSON boundary (two PRs)

Does **not** block modu P4. Lands in 0.4.

### P2a — Input: integer-valued JSON numbers become `IntVal`

- **Goal:** `{"n": 12345}` yields `IntVal(12345)` so env-sourced integer
  arithmetic is exact; fractional numbers unchanged.
- **Files / changes:** `playground/web/web.mbt` `json_to_value` — the match at
  `:159` currently discards everything but the double (`Number(d, ..)`).
  **Primary technique:** the `..` is core's raw-string component (core
  `json/lex_number` preserves representation for numbers it cannot round-trip
  — first a 30-min in-PR spike confirms whether small-int literals keep the
  raw string; if yes, map `raw`-bearing integer tokens in int64 range to
  `IntVal`, letting `5` → `IntVal(5)` while `5.0` → `NumVal(5.0)`).
  **Fallback:** `d.is_integer() && |d| <= 2^53-1` heuristic (accepts `5.0` as
  int — needs Decision 4).
- **ABI impact:** none (no new exports); behavior change → CHANGELOG +
  `describe_abi` note; version 0.4.0.
- **Conformance anchors:** `.n + 1`, `.a * .b` (both int — stays int; wrap
  reachable, see Decision 5), mixed promotion, `sum` over int arrays stays
  `IntVal` (`evaluator/aggregates.mbt:105-127` already supports it), legacy
  Jexl path unchanged semantics (untyped ops degrade to double — verify
  `==` across int/double, Decision 7). Mirror anchors in modu's conformance
  corpus for the eventual vendor swap.
- **Acceptance:** `moon test` full green; new test: canonical serialization of
  `{"n": 5}` env + `.n + 1` shows `6` (not `6.0`-shaped double) on **both**
  engines (walk + VM); `9.2e18` (beyond 2^53) stays double per scope.
- **Depends on:** Decisions 4, 5 (and 7 for the Jexl note).
- **Effort:** 1 人日.
- **Risk / rollback:** semantic change to env arithmetic; silent Int64 wrap
  on int∘int multiply of large env values (Go parity — document, don't guard).
  Rollback: revert the PR; input/output changes are independent.

### P2b — Output: typed JSON writer for `IntVal`

- **Goal:** resolve the in-source "documented divergence" — `IntVal` results
  serialize with exact digits instead of `to_double()`.
- **Files / changes:** `builtin/helpers.mbt:189-200` (`value_to_json`) —
  primary: emit core `Json::Number(i.to_double(), Some(i.to_string()))` if
  the core serializer honors the raw string (same 30-min spike as P2a,
  shared); fallback: custom writer branch for `IntVal`.
- **Conformance anchors:** `IntVal(2^60)` (from literals/bitwise) serializes
  exact digits; round-trip note: >2^53 values re-enter as doubles until the
  input side gains raw-int64 mapping (explicitly out of P2a scope).
- **Acceptance:** `moon test` green; new test asserting exact-digit output;
  the `helpers.mbt:198-200` comment is removed or rewritten as resolved.
- **Depends on:** nothing (parallel with P0/P1).
- **Effort:** 0.5 人日.
- **Risk / rollback:** output-only; revert if core's serializer ignores the
  raw string and the fallback misbehaves.

## P3 — 0.4 cheap item B: divide-by-zero error (one PR)

Does **not** block modu P4, but the chosen semantics feed modu's
rule-writing discipline (P5-2) — decide before modu P4's spec freeze.

- **Goal:** kill the silent-Inf hazard: today `x / y > 0.5` with `y == 0`
  evaluates **true** (`evaluator/evaluator.mbt:447-454` — "1/0 = +Inf; no
  divide-by-zero error").
- **Semantic options (Decision 3):**
  - (i) keep +Inf everywhere (status quo; judge rules must self-guard);
  - (ii) standard dialect always errors — loudest, diverges from expr's float
    behavior;
  - (iii) opt-in flag — extra surface for a narrow fix;
  - **(iv) recommended:** `IntVal` divisor 0 → error; `NumVal 1.0 / 0.0` →
    ±Inf (mirrors Go/expr int-vs-float semantics; with P2a landed, judge
    rules over integer cents fail loudly while float math keeps parity).
- **Files / changes:** `evaluator/evaluator.mbt` `divide` (`:447-454`) and
  the VM path (audit whether `evaluator/vm.mbt` shares the arith helper);
  audit `%` by zero in the same PR; error message + code (modu's
  `errorCodes.ts` mapping note goes to P5); `docs/en/parity-contract.md`
  entry; CHANGELOG.
- **Conformance anchors:** `1/0`, `1.0/0.0`, `-1/0`, `x % 0` on both engines;
  run the **full existing corpus first** — if `1/0 = +Inf` is already an
  anchor, the change breaks it (Decision 3's first input).
- **Acceptance:** `moon test` green including new anchors; parity-contract
  updated; CHANGELOG behavior-change entry.
- **Depends on:** Decision 3 (and lands after P2a if option (iv) is chosen,
  so IntVal-division paths exist).
- **Effort:** 0.5 人日.
- **Risk / rollback:** semantic change; revert PR if corpus fallout exceeds
  appetite.

## P4 — Deferred decimal: design note only (folds into P0's M3 rewrite)

No implementation is scheduled. Does **not** block anything.

- **Trigger conditions (business signals, all required):** a modu vertical
  needs fractional money math (tax/rate/FX) **inside judge rules**, AND a
  differential test fails reproducibly under double, AND the requirement is
  exactness (not precautionary). Absent all three, (a)-discipline + lint
  covers modu.
- **Design sketch (for the 0002 M3 text):** `DecVal` variant reusing
  `moonbitlang/x/decimal` (mooncakes, `max_scale = 28`); boundary protocol =
  **decimal columns cross as JSON strings + explicit `dec($in.col)`/`dec("12.30")`
  parse — explicit opt-in per expression**; decimal∘decimal exact;
  decimal mixed with float/NumVal → compile+runtime error (forces the
  discipline); `sum` gains a decimal accumulator branch; output via the P2b
  typed writer; **no** checker `Nature::DecN` initially. Budget as a focused
  0.5.0-scale release.
- **Why it does not solve governance (state explicitly in M3):** the checker
  is env-blind (`expr/check.mbt:11-15`, `:235-238`) — column reads stay
  `UnknownN` with or without a decimal type; "decimal column double-accumulated"
  is unenforceable in the language in every world. The `dec()`-wrap itself is
  enforceable **only** host-side (modu lint requires the wrap on
  decimal-typed columns). Governance cost never moves from host to language.
- **Effort:** 0.5 人日 (the design depth beyond P0's re-base).

## P5 — modu handoff (pointers only; deliverable lives in the modu repo)

These are modu-P4-internal acceptance items, not mbel work. The modu-side
feedback doc (separate, ~0.5 人日) should carry exactly:

1. **Schema-aware lint — mandatory** (the review's central governance point):
   modu `packages/core/src/logic/validate.ts` + models schema — warn/error
   when expressions use `sum`/`avg`/`/`/`**` over decimal-typed columns, or
   `==` on float arithmetic results. This is the **only** enforcement point
   for numeric discipline (checker env-blindness).
2. **Divide guard discipline:** rule-writing rules must guard divisions
   (`y != 0`) until 0.4's P3 semantics land; update modu's business-logic.md
   rule-writing section with the chosen semantics.
3. **Integer discipline:** money enters expressions as minor integer units ≤
   2^53; document; optional lint warning on raw decimal-column arithmetic.
4. M0-1 caret-block parsing and M0-2 builtin reserved list — already in
   modu's plan; carry the review's corrections (must-fix #6, retirement
   condition).
5. Vendor-swap checklist when 0.4 is consumed (see next section) — new
   conformance anchors must merge **before** the wasm swap.

## 版本与发布流程（0.4 runbook）

1. **Version:** `0.4.0` (minor): additive exports (if M2 survives P1) +
   behavior changes (P2a input parsing, P2b output writer, P3 divide).
2. **CHANGELOG** `[0.4.0]` entry with explicit behavior-change notes (env
   integer parsing; IntVal output; divide semantics).
3. **ABI gate:** update `describe_abi` + `playground/mbel.abi.json`;
   `tools/check_abi.mjs` CI green (manifest/artifact equality — the 0001-P0
   mechanism).
4. **Build:** rebuild wasm; filename `mbel-0.4.0.wasm`; record sha256.
5. **Conformance:** `moon test` full; both engines for every P2/P3 anchor;
   modu conformance corpus anchors merged in modu's repo **before** swap.
6. **modu vendor swap (single PR, in order):** add wasm + update
   `packages/core/src/mbel/kernel.ts` (version constant + sha256) → merge
   conformance anchors → if 0.4 bundles 0001-P4 strict mode, retire M0-2's
   hardcoded builtin list in the same PR (Decision 6) → run `verify:logic`
   full + `verify:provider` + `check:boundaries` → delete the old wasm file.
   No dual-version coexistence.
7. **Rollback:** revert the vendor PR; old artifact restored from git.

## 不做的事

- Full checker-typed decimal (`Nature::DecN` static lattice) — pointless
  machinery under an env-blind checker.
- M2 host-import channel in 0.4 — gated on P1 verdict + a 0001 non-goal
  revision decision; default posture is *not pursued* unless P1 = 不可用 **and**
  modu still wants expression-level host calls.
- Arbitrary-precision bigint; Unicode case mapping (strutil follow-up);
  integer division for `/`; threading runtime positions into `EvalErr`
  (M0-1's parsing covers the near-term need).

## 需要拍板的决策点

1. **M3 根基重写**（P0-2/P4 的前提）：接受审稿版重写 — boundary-loss 定位 +
   拆出 P2/P3 便宜件 + (c) 记为 named-trigger deferred？默认：接受。
2. **mooncry 门槛写进提案正文**（P0-8）：默认写（作为 M2 的第一道门）。
3. **除零语义**（P3）：**已裁决（2026-11-03）：(i) 维持 +Inf**。既有
   双引擎 parity 锚点（`typed_test.mbt:60`、`vm_parity_test.mbt:92`）与
   Jexl 语料保持 `1/0 = +Inf` 不动；P3 从 0.4 范围移除，modu 侧
   `y != 0` 守卫转为**常设纪律**（modu lint 执法）。
4. **输入整数化规则**（P2a）：**已裁决（2026-11-03）：(a)
   `is_integer && |d| ≤ 2^53-1` 一刀切**。`5.0` 与 `5` 不可区分、都成
   `IntVal`；边界实现取 `d.floor() == d && |d| ≤ 2^53-1`（2^53 本身
   排除——整数字面量 ≥ 2^53 以 `repr` 到达且 double 在那里撞名，
   映射成 `IntVal` 会冒充精确）。
5. **int∘int 乘法 silent wrap 可达性**（P2a）：**按默认接受并文档化**
   （Go parity；锚点 `4294967296 * 2147483648 → int:-9223372036854775808`），
   modu lint 提示留给 modu 侧。
6. **0.4 是否捆绑 0001-P4（strict 注册）**：未裁决，维持待定。
7. **Jexl 可见性**（P2a）：**按默认边界共享**（单一 `json_to_value`，
   三副本同步改）。已记录行为变更：legacy 方言中 `IntVal` 操作数走
   typed 运算路径，`"x" + n`（env 整数）从字符串拼接变为类型错误；
   纯数值结果不变。CHANGELOG 已注明。

## Effort summary

| Phase | Effort | Blocks modu P4? |
| --- | --- | --- |
| P0 0002 revision (docs) | 1 人日 | No (blocks 0002 acceptance) |
| P1 mooncry spike | 0.5 人日 | No (blocks M2 立项 only) |
| P2a integer-exact input | 1 人日 | No |
| P2b typed writer | 0.5 人日 | No |
| P3 divide-by-zero | 0.5 人日 | No (feeds modu rule discipline) |
| P4 decimal design note | 0.5 人日 | No |
| P5 modu handoff doc (modu repo) | 0.5 人日 | Its lint item is a must-do **inside** modu P4 |
| 0.4 release engineering | 0.5 人日 | No |
| **Total** | **≈ 5 人日** (mbel side) + 0.5 人日 (modu side) | — |

## Execution log (2026-11-03)

- **P0 done.** All 8 must-fixes applied to 0002 (M3 re-based, gap 6 added,
  M0 item 3 added, mooncry gate recorded with the P1 verdict below).
- **P1 done — verdict: 可直接用.** `mooncry@0.95.0` (released 2026-09-20,
  Apache-2.0, zero deps) ships native `argon2id` (RFC 9106, vectors
  cross-checked against argon2-cffi); constant-time verify composes as
  `argon2id` + `bytes_equal`. Scratch spike reproduced the library vector and
  a hash/verify round-trip (t=3, m=19456, p=2). **M2 loses its necessity for
  hashing**; gate status recorded in 0002 §5.
- **P2b done — already landed upstream, minus dead code.** The typed writer
  exists (`to_json_string`, `builtin/helpers.mbt`; exact-int64 `toJSON`
  anchors in `expr_test/typed_test.mbt:134,137`), and result envelopes
  serialize `IntVal` exactly (`canon`). The review's "documented divergence"
  cited `value_to_json` — dead code with no callers — now deleted with its
  stale comment. `moon test` 278/278 green. (The 6 `moon check --deny-warn`
  errors are pre-existing toolchain deprecations in `ast`/`grammar`, present
  on the clean tree.)
- **P2a spike result — primary technique dead, fallback needs Decision 4.**
  Core's JSON lexer sets a number's raw-representation component **only**
  when the value cannot round-trip as a double (`lex_number.mbt` fast path:
  small integers ≤ 2^53 return `repr: None`), so `5` and `5.0` are
  indistinguishable at the `Json` layer. The fallback is the `is_integer &&
  |d| ≤ 2^53-1` heuristic (accepts `5.0` as `IntVal`) — **requires the
  second ruling the plan reserved**. Bonus finding: integers > 2^53 that fit
  int64 *do* carry `repr` (`9007199254740993` arrives as
  `Number(9.22e18, repr="9007199254740993")`-style), so exact big-int64
  input mapping is possible later if wanted (out of P2a scope as written).
  Three synced `json_to_value` copies must change together:
  `playground/web/web.mbt`, `cmd/main/main.mbt`, `builtin/helpers.mbt`
  (the `fromJSON` builtin inherits).
- **P3 pre-check done — `1/0 = +Inf` IS an existing anchor.**
  `expr_test/typed_test.mbt:60` (`"1 / 0" → "float:inf"`),
  `engine_test/vm_parity_test.mbt:92` (both engines), and the legacy Jexl
  corpus (`corpus_data_test.mbt`: `"1/0"`, `"-1/0"`, `"0/0"`, `"age / 0"`,
  `"[0/0][0] == 0/0"`). Any (iv)-style change breaks these anchors and is a
  parity-contract decision. `5 % 0` already errors — `/` is the only gap.
  **Blocked on Decision 3 as written.**
- **Rulings received (2026-11-03): Decision 4 = (a), Decision 3 = (i).**
  Decisions 5 and 7 taken at plan defaults (accept+document wrap; shared
  boundary). Decision 6 remains open.
- **P2a implemented — fallback (a), bound tightened to 2^53 − 1.** All three
  synced `json_to_value` copies (`playground/web/web.mbt`,
  `cmd/main/main.mbt`, `builtin/helpers.mbt` — `fromJSON` inherits) map
  `d.floor() == d && |d| ≤ 9007199254740991.0` to `IntVal`. The initially
  applied code used `≤ 2^53`; corrected after reading core
  `lex_integer_end`: integer literals ≥ 2^53 arrive as
  `Number(double, repr~Some(_))` where the double already aliases neighbors
  (2^53 + 1 parses to the same double as 2^53), so a `≤ 2^53` bound would
  emit an off-by-one `IntVal(2^53)` for the input `9007199254740993` —
  exactness it does not have. At/beyond 2^53 stays `NumVal` (out of scope;
  repr-based exact int64 mapping remains future work).
- **P2a fallout: one anchor updated, by design.**
  `engine_test/builtin_test.mbt` `fromJSON("[1,2,3]")[1]` now expects
  `IntVal(2L)` (the boundary change is inherited by `fromJSON`). Legacy-dialect
  behavior change recorded in CHANGELOG: `IntVal` operands take the typed
  operator path, so `"x" + n` over an integer env value is a type error
  instead of concatenation; numeric results unchanged. The want-table and
  parity corpora pass untouched (their expectations are canon-value based,
  and IntVal/NumVal print identically there).
- **P2a anchors added.** `expr_test/typed_test.mbt`: env-based
  `expect_typed_env` harness + 14 anchors (`n+1 → int:6` both `5`/`5.0` →
  IntVal, `5.5`/`9.2e18`/`9007199254740993` → float, boundary
  `9007199254740991` → int / `9007199254740992` → float, `sum` int/float,
  wrap, cross-class `==`). `engine_test/vm_parity_test.mbt`: dual-engine
  anchors incl. `n / 0` → +Inf (Decision 3 = (i) locked).
  `moon test` 280/280 green.
- **P3 closed — (i), no code change.** Status quo maintained (expr parity
  preserved; existing anchors keep `1/0 = +Inf`). Removed from 0.4 scope;
  modu's divide guard becomes a permanent rule-writing discipline, enforced
  by modu's schema-aware lint (P5-2 wording updated accordingly).
- **mooncry link/version note.** The user-cited source link points at the
  `mooncry@0.2.1` docs page, whose KDF list has only HKDF/PBKDF2 (no
  argon2id) — that is the old version. The registry's latest is `0.95.0`
  (2026-09-20), which provides the full argon2 family (`argon2id` /
  `argon2i` / `argon2d` / generic `argon2`, RFC 9106) plus scrypt, the
  blake2 family, and a wide primitive set. The P1 verdict 可直接用 is
  consistent with 0.95.0 and stands. Caveat worth carrying into any M2/M1
  decision: the library self-describes as correct-but-**not formally
  audited**, and AES is table-based (not constant-time); argon2id + a
  constant-time `bytes_equal` verify composition avoids both caveats.
- **Docs updated for P2a.** `docs/en/environment.md` + `docs/zh/environment.md`
  (JSON mapping paragraph + example now show `IntVal 36`); CHANGELOG
  `[Unreleased]` behavior-change entry added.
