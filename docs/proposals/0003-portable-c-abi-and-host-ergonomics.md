# Proposal: a portable C-ABI wasm artifact and the host-ergonomics gaps around it

- **Status:** Landed (0.5.0) — P0–P6 shipped; see CHANGELOG and
  `docs/{en,zh}/wasm-embedding.md`
- **Date:** 2026-11-04
- **Target:** 0.5.0
- **Author:** mbel maintainers (third-party embedding review)
- **Related:** `docs/proposals/0001-user-functions-for-embedders.md` (P1 compiled
  function set and P5 structured error codes are absorbed here as P2 and P3;
  0001's P3/P4/P6/P7 stay open and are not duplicated),
  `playground/web/moon.pkg`, `playground/web/web.mbt`, `playground/mbel.abi.json`,
  `tools/check_abi.mjs`, `AGENTS.md` (Playground / WASM)

## TL;DR

The shipped artifact is a **JS-string ABI**: `wasm-gc` plus
`use-js-builtin-string`, so a host must implement the GC proposal, the JS String
Builtins proposal, and inject a string-constant module named `"_"`. That is a
real constraint, and it is the whole reason "third-party language support" is
currently a JS-only story.

**The finding that changes the shape of this proposal:** the portable path is
not speculative. A probe build of the current source for the `wasm` (MVP) target
produced a memory-bearing artifact with **no GC and no js-string requirement**,
and a plain WebAssembly host drove it end to end — `eval_expr("a * 2 + 1",
{"a": 20}, "vm")` returned `41`, `eval_checked` returned the checker envelope —
using nothing but `DataView` and a UTF-16 buffer. Release size 740,102 B versus
605,590 B for the js-string artifact (+22%).

So the ask is not "make wasm work outside JS". The ask is:

1. **P0** — ship a second artifact for the `wasm` (MVP) target, and turn the
   reverse-engineered string layout into a **guarded, documented contract**
   instead of an accident of the current runtime;
2. **P1** — declare host requirements in the ABI manifest (today a non-JS host
   discovers the js-string requirement by crashing);
3. **P2** — a session handle (absorbs 0001 P1): today every call re-parses and
   re-checks the whole functions file, measured at **106× a plain eval** with
   200 functions;
4. **P3** — `$code` / `$pos` in the error envelope: `$code` is **declared in the
   manifest but never emitted** (absorbs 0001 P5);
5. **P4** — per-call budgets: `limits` is advertised read-only, and a host cannot
   tighten `max_steps` for untrusted rules;
6. **P5/P6** — manifest single-source, ABI compatibility policy, and an
   embedder-facing doc page with runnable bindings.

## Minimum viable path (and what is *not* required)

| Milestone | Change | What it buys |
| --- | --- | --- |
| **M0 — use it today** | No mbel change | A JS host (Node ≥ 24, Chrome/Edge 130+, Firefox 134+, Safari 18.4+) can call the existing eight exports. Non-JS hosts cannot start. |
| **M1 — portable** | P0 + P1 | Rust / Python / Go / C hosts instantiate and evaluate. This is the milestone the phrase "third-party language support" actually refers to. |
| **M2 — usable at scale** | P2 + P3 + P4 | One registration per process instead of per call; errors a host can branch on; budgets a host can tighten. |
| **M3 — socialised** | P5 + P6 | Bindings and docs so a new embedder does not reverse-engineer anything. |

## 1. What exists today (source and probe evidence)

| Capability | Where | Status |
| --- | --- | --- |
| Eight JSON-string exports | `playground/web/web.mbt`, `playground/web/moon.pkg` | shipped (0.4.0) |
| ABI manifest + `describe_abi()` + CI check | `playground/mbel.abi.json`, `tools/check_abi.mjs` | shipped (0.4.0) |
| Checked registration (bodies, arity, unknown calls) | `engine/userfuncs.mbt` | shipped (0.4.0) |
| Integer-exact JSON input | `json_to_value` (three copies) | shipped (0.4.0) |
| `Engine::set_limits` | `engine/engine.mbt:91` | exists internally, **not exported** |
| `budget_stats()` observability | `engine/engine.mbt` | exists internally, **not exported** |
| `wasm` (MVP) build of the engine | `moon build --target wasm` | **builds, 0 errors** (probe, App. A) |
| Session / handle | — | absent (0001 P1 pending) |
| `$code`, `$pos` | manifest declares `$code` | **never emitted** |
| Embedder doc page | `AGENTS.md` §Playground only | absent for external hosts |

Host compatibility, measured against the committed 0.4.1 artifact:

| Host | Result |
| --- | --- |
| Node 24 + `builtins:['js-string']` + `importedStringConstants:'_'` | works |
| Node 24, plain `WebAssembly.compile` | fails: `Import #1 "_" is not an object or function` |
| Node 22, same options | fails: identical error (string-constant module not provided) |
| Node 20 | fails at compile: no GC proposal (`Unknown type code 0x50`) |
| wasmtime / wazero / wasmer (Rust, Python, Go, C) | not possible: JS String Builtins is a JS-embedding feature |

## 2. Gap list with cause attribution

| # | Gap | Cause | Consequence |
| --- | --- | --- | --- |
| 1 | Only a JS-string channel exists | link profile is `wasm-gc` + `use-js-builtin-string` | non-JS hosts cannot instantiate at all |
| 2 | Host requirements are undiscoverable | manifest has no `hostRequirements` field | integration fails at instantiation, not at design time |
| 3 | No session; every call re-registers | `eval_with_functions` parses + validates per call | 106× overhead at 200 functions (App. A.3) |
| 4 | `$code` declared, never emitted | `error_out` writes `$error` only | hosts match message text by substring |
| 5 | No machine-readable error position | `(L:C)` lives inside the message string | editors must regex the prose |
| 6 | Budgets not settable from the ABI | `set_limits` is MoonBit-only | untrusted rules run at default 1M steps |
| 7 | Manifest is a hand-written string | `web.mbt:22` duplicates `mbel.abi.json` | every bump touches three places |
| 8 | No ABI compatibility policy | `abiVersion: 1` exists, semantics unstated | downstream cannot plan upgrades |
| 9 | No bindings or embedder docs | docs cover the language, not the artifact | each host re-derives the string convention |

## 3. P0 — a C-ABI artifact on the `wasm` (MVP) target

### What was verified

Building the **current, unmodified engine** for `wasm`:

```
moon build --target wasm          # 0 errors, 156 pre-existing deprecation warnings
→ web.wasm, memory exported, imports: wasi_snapshot_preview1.fd_write,
  __moonbit_time_unstable.now  (both trivially stubbable)
```

A host that knows nothing about MoonBit can then:

| Call | Result |
| --- | --- |
| `describe_abi()` | full manifest JSON |
| `dump_ast("1 + 2")` | `bin(+,int:1,int:2)` |
| `eval_expr("a * 2 + 1", {"a": 20}, "vm")` | `41` |
| `eval_checked("1 + \"a\"", "{}", "walk")` | `{"$error":"invalid operation: + (mismatched types int and string) (1:3)…"}` |

### The string convention (and why it must be locked)

On this target a MoonBit `String` is a pointer to UTF-16LE data with a 4-byte
character count immediately before the pointer:

```
[ u32 char_count ][ utf16le code units … ][ 0x0000 ]
                    ^ pointer passed across the ABI
```

Verified in both directions: a returned `describe_abi()` is readable as
UTF-16LE with the length taken from `ptr - 4`, and a host-authored buffer built
that way is accepted as an argument (`dump_ast` parsed it correctly).

This works **today** but it is runtime-internal. A toolchain upgrade may change
it silently, and any host that hardcodes it becomes load-bearing on an
undocumented layout. Therefore:

- **P0.1** — write the layout down in `playground/mbel-cabi.md` (both artifacts'
  string conventions, the two required stubs, the calling order).
- **P0.2** — add `tools/check_abi.mjs --cabi`: instantiate the MVP artifact with
  stubs, assert `describe_abi()` round-trips through the documented layout,
  assert a host-authored argument is parsed, assert the four calls above. **A
  toolchain bump that changes the layout now fails CI instead of failing a
  customer.**
- **P0.3** — export an `abi_layout()` function returning a small JSON
  (`{"stringEncoding":"utf16le","lengthPrefix":"u32","headerOffset":-4,
  "terminator":2}`) so hosts can assert at runtime rather than at install time.

If a future toolchain drops the layout, P0.2 fails loudly and the fallback is
either an explicit `(ptr, len)` surface (needs a pointer/alloc intrinsic that
core does not expose today) or a native `cdylib` for non-wasm hosts. That
decision is deferred until the test actually fails — not before.

### Build wiring

`playground/web/moon.pkg` gains a second link profile:

```moonbit
"wasm": { "exports": [ … same eight names … ] }   // no use-js-builtin-string
```

**Watch the DCE trap:** with no `wasm` profile declared, the build succeeds and
emits a **259-byte** artifact exporting only `memory` and `_start` — every
export is dead-code-eliminated because `main` is `ignore(0)`. This is easy to
mistake for "the backend doesn't work"; it is only a missing export list.

### Artifact naming

| File | Target | Host contract |
| --- | --- | --- |
| `playground/mbel.wasm` | wasm-gc + js-string | Node ≥ 24, browsers as listed |
| `playground/mbel-cabi.wasm` (new) | wasm (MVP) | any host with the MVP proposal |

Both come from one source tree and one release commit; `describe_abi()`
identifies which one is loaded, and `abiVersion` stays a single number because
the JSON surface is identical.

## 4. P1 — host requirements in the manifest

Add one object to the manifest and to `describe_abi()`:

```json
"hostRequirements": {
  "target": "wasm-gc",
  "needsGcProposal": true,
  "needsJsStringBuiltins": true,
  "importedStringConstants": "_",
  "imports": ["__moonbit_time_unstable.now"],
  "minNode": 24,
  "browsers": { "chrome": 130, "edge": 130, "firefox": 134, "safari": "18.4" }
}
```

and for the C-ABI artifact `{"target":"wasm","needsGcProposal":false,
"needsJsStringBuiltins":false,"imports":["wasi_snapshot_preview1.fd_write",
"__moonbit_time_unstable.now"]}`.

This is the cheapest item in the proposal and removes the most common
integration failure: a host cannot otherwise tell, before shipping, that Node 22
will refuse to instantiate the module.

## 5. P2 — session handle (absorbs 0001 P1)

Today `eval_with_functions` parses the functions file, validates it, compiles
every body, and re-registers checked arities **on every call**. Measured on the
0.4.1 artifact:

| Call | Cost |
| --- | --- |
| `eval_expr`, 2-field env | 0.004 ms |
| `eval_with_functions`, 2 functions | 0.016 ms |
| `eval_with_functions`, **200 functions** | **0.475 ms** |

The last row is 106× a plain eval, and it is entirely repeat work: the same file
is parsed and the same bodies are checked for identical input. For a rules
engine evaluating hundreds of expressions per request this dominates.

```
create_session(funcs_json, mode, engine) -> {"handle":"s-1","functions":[…]}
eval_session(handle, expr, env)          -> result
describe_session(handle)                 -> {"mode":…,"engine":…,"functions":[…]}
release_session(handle)                  -> {"ok":true}
```

Semantics:

- `create_session` is atomic: on any validation error nothing is registered.
- The handle is **instance-scoped** and immutable; using a released or unknown
  handle is `{"$error":…,"$code":"HANDLE_UNKNOWN"}`.
- Cap live sessions at 16 (`HANDLE_LIMIT`); a wasm instance is single-threaded,
  so no locking is implied or provided.
- `eval_with_functions` stays exactly as it is: create + eval + release sugar.
  Existing hosts and the playground do not change.

Acceptance: the two paths produce identical values and error messages across the
function corpus, both engines, three targets.

## 6. P3 — structured errors: `$code` and `$pos` (absorbs 0001 P5)

The manifest already advertises `{"message":"$error","code":"$code"}`; no code
path emits `$code`. Hosts therefore classify errors by matching message prose —
modu does exactly that today.

Add two optional fields, message text unchanged:

```json
{ "$error": "invalid operation: + (mismatched types int and string) (1:3)\n | 1 + \"a\"\n | ..^",
  "$code": "CHECK_TYPE",
  "$pos": { "line": 1, "col": 3 } }
```

Proposed vocabulary (stable; adding a code is a minor release, renaming one is
major):

| Family | Codes |
| --- | --- |
| Host input | `ENV_JSON`, `FUNCS_JSON`, `FUNCS_VERSION`, `MODE_UNKNOWN`, `ENGINE_UNKNOWN`, `HANDLE_UNKNOWN`, `HANDLE_LIMIT` |
| Parse | `PARSE_SYNTAX`, `PARSE_EMPTY`, `PARSE_TOO_LARGE`, `PARSE_TOO_DEEP` |
| Check | `CHECK_TYPE`, `CHECK_UNKNOWN_NAME`, `CHECK_UNKNOWN_FUNCTION`, `CHECK_ARITY`, `CHECK_FUNC_BODY` |
| Runtime | `RUNTIME_TYPE`, `RUNTIME_UNKNOWN_CALL`, `RUNTIME_RECURSION`, `RUNTIME_BUDGET` |
| Internal | `INTERNAL` (never expected; hosts may alert) |

`$pos` is emitted wherever a position exists today (parse errors and
Compile-mode checker errors); the engine-level `unknown name x` has none and
omits the field. `$code` is diagnostic-stable, not a substitute for the message:
both are kept so existing substring hosts keep working.

## 7. P4 — per-call budgets

`describe_abi().limits` reports defaults (10k nodes / 10k depth / 1M steps /
256 user-fn depth) but a host cannot lower them. `Engine::set_limits` already
exists, so this is an export, not an engine change:

```
eval_with_limits(expr, env, engine, limits_json) -> result
configure_session(handle, limits_json)           -> {"ok":true}
```

`limits_json` accepts a subset (`{"maxSteps":10000}`); absent keys keep the
defaults; `0` still means "disabled" as documented. Budget failures keep their
exact current messages (contract-locked) and gain `$code: "RUNTIME_BUDGET"`.

This is the difference between "the engine has a DoS guard" and "the host can
set the guard for untrusted input".

## 8. P5 — manifest single source and ABI compatibility policy

- **Single source.** `playground/mbel.abi.json` is canonical; a small generator
  (`tools/gen_abi_mbt.py` or a build step) emits the MoonBit literal in
  `describe_abi()`. CI runs the generator and fails on a non-empty diff, which
  removes the three-place version bump without adding a runtime cost.
- **Policy.** Written once in `docs/en/wasm-embedding.md` and referenced from
  `AGENTS.md`:
  - *Major* — removing/renaming an export, changing a parameter's meaning,
    changing envelope keys, changing the string layout.
  - *Minor* — new exports, new optional fields (`$code`, `$pos`,
    `hostRequirements`, `abi_layout`), new error codes.
  - *Patch* — no ABI change.
  - N-1 support: the previous `abiVersion` keeps receiving security fixes for
    one minor cycle; `describe_abi()` is the only negotiation mechanism.

## 9. P6 — embedder documentation and bindings

- `docs/en/wasm-embedding.md` + `docs/zh/wasm-embedding.md`: which artifact to
  pick, the two required stubs, the string layout, the error envelope, the
  session lifecycle, and the minimum host versions.
- TypeScript definitions for the js-string artifact (`playground/mbel.d.ts`),
  checked by `tsc --noEmit` in CI.
- Three runnable examples in `tools/bindings/`: Node (exists partly as
  `check_abi.mjs`), Python (`wasmtime-py`, proves the C-ABI path), and Rust
  (`wasmtime` crate, smoke only). Each must evaluate one expression and one
  checked error, so the examples double as cross-host conformance tests.

## 10. Compatibility and sequencing

All ABI changes here are additive; the eight existing exports keep their
signatures and semantics, and the functions file format stays at v1.

| Release | Items | Gate |
| --- | --- | --- |
| 0.5.0 | P0 (artifact + layout guard), P1, P6 (docs, Python/Rust examples) | portable round-trip verified in CI on the pinned toolchain |
| 0.5.0 | P3 (`$code`/`$pos`), P4 (limits) | existing suites unchanged; `$code` asserted per family |
| 0.5.1 | P2 (session) | 200-function corpus: identical results, ≥50× lower per-call cost |
| 0.5.x | P5 (generator, policy) | generator diff empty in CI |

P0 before P2 on purpose: portability is the item that gates other languages,
while the session is an optimisation for hosts that already work.

## 11. Security

- The sandbox properties do not change: no FFI, no reflection, no host calls,
  deterministic evaluation. The MVP artifact imports exactly two functions, both
  stubbable with constants.
- The C-ABI artifact moves string handling into **host-written memory**. A host
  that writes a bad `char_count` can corrupt its own instance; the conformance
  test covers the supported path, and `abi_layout()` lets a host assert before
  trusting it. This is a host-side risk, not an engine-side one, and must be
  documented as such.
- `configure_session` can *lower* budgets. It must not be able to raise them
  above the compiled defaults without an explicit `allowRaise` flag, so a
  misconfiguration cannot silently disable the DoS guard.
- Host callbacks remain a non-goal (0001 §3, 0002 §5): a host that wants new
  functions recompiles the engine.

## 12. Acceptance criteria

1. `playground/mbel-cabi.wasm` is built from the same commit as
   `playground/mbel.wasm`, instantiates under Node with the two stubs, and
   passes `tools/check_abi.mjs --cabi`.
2. A Python (`wasmtime-py`) example in `tools/bindings/` evaluates an expression
   and a checked error against the C-ABI artifact, with no V8 involved.
3. `describe_abi()` on both artifacts reports the same `abiVersion`, the same
   export list, and an accurate `hostRequirements`.
4. `$code` is emitted for at least one case in every family in §6, asserted in
   `check_abi.mjs`; `$pos` is present for parse and Compile-mode checker errors.
5. `eval_with_limits` with `{"maxSteps": 100}` fails a long expression with the
   documented budget message plus `RUNTIME_BUDGET`, and the default limits are
   unchanged when the parameter is omitted.
6. With 200 functions, `create_session` + 200 × `eval_session` costs at most 1/10
   of 200 × `eval_with_functions` on the same artifact, with identical results.
7. The generator in P5 leaves `git diff` empty, and a deliberate edit to
   `mbel.abi.json` fails CI.
8. Three-target suite (wasm-gc, js, native) stays green; the MVP artifact is
   built but not added to the test matrix beyond the conformance run.

## 13. Alternatives considered

- **Keep the js-string artifact as the only channel.** Defensible while modu is
  the only consumer (it runs Node). It stops being defensible the moment a
  second language asks, and the probe shows the cost of not doing it is one link
  profile plus a conformance test.
- **Explicit `(ptr, len)` exports instead of native `String`.** Cleaner on
  paper, but MoonBit core exposes no pointer or allocator API, so this needs a
  runtime intrinsic. Deferred behind P0.2: if the layout test ever fails, this
  becomes the fallback.
- **A native `cdylib` for Python/Rust/Go.** Solves the same problem outside
  wasm, loses the sandbox and the single-artifact story, and duplicates the ABI.
  Only worth it if the MVP path breaks.
- **`eval_with_functions_cached(key, …)` instead of handles.** Implicit state
  with eviction rules; 0001 §10 already flagged this. Handles are explicit and
  auditable, and the cap makes leaks visible.
- **Substring error matching (status quo).** Works today, breaks the moment a
  message is reworded — and messages are contract-locked precisely because they
  are load-bearing.

## 14. Open questions

1. **Artifact naming.** `mbel-cabi.wasm` vs `mbel-mvp.wasm` vs
   `mbel-portable.wasm`. "cabi" is accurate for hosts but says nothing about
   wasm; "portable" says nothing about the calling convention.
2. **String encoding at the ABI.** UTF-16 is what the runtime uses; a UTF-8 view
   would halve the copy for non-JS hosts but requires a conversion layer. Is the
   extra layer worth it before a host actually asks?
3. **Session cap.** 16 is a guess. Should it be a `limits` field so hosts with
   many tenants can raise it deliberately?
4. **`$pos` shape.** `{line, col}` 1-based, or a byte offset too? Editors want
   the offset; rules authors want line/col.
5. **`abi_layout()` vs a compile-time constant.** A function can be checked
   mechanically; a constant in the docs is simpler to read. Both is also fine,
   just not free.
6. **Budget-lowering baseline.** `check_lowered` compares a request against
   the *compiled default*, not the *current* value: after lowering
   `maxSteps` to 100, a later request of 100 000 (still under the default)
   is accepted. This is the landed semantics — each configure call is an
   independent request, and legal multi-turn tuning needs no `allowRaise`.
   The alternative ("monotonic lower-only", compare against the current
   value) makes the budget a high-water mark: any tightening is
   irreversible without `allowRaise`, an untrusted caller can never undo a
   host's tightening, and "current budget = historical minimum" makes
   audit reasoning single-point. Cost: a mis-tightened session must be
   re-raised via `allowRaise` or rebuilt. Switch the baseline the day an
   untrusted party can reach `configure_session` / embedded limits config
   (e.g. if rules files are ever allowed to carry limits); until then the
   independent-request semantics is deliberate.

## Appendix A — probe evidence (2026-11-04, pinned toolchain 0.10.19+97801ee1b)

### A.1 Host matrix against the committed 0.4.1 artifact

```
Node 24 + js-string + importedStringConstants "_"  → eval_expr("1 + 2") = 3
Node 24 plain compile                              → Import #1 "_" is not an object or function
Node 22 + same options                             → same failure
Node 20                                            → Unknown type code 0x50 (no GC proposal)
```

### A.2 `wasm` (MVP) target, unmodified source

```
moon build --target wasm              → 0 errors  (156 pre-existing warnings)
debug artifact                        → 1,816,587 B
release artifact                      →   740,102 B   (js-string release: 605,590 B, +22%)
imports                               → wasi_snapshot_preview1.fd_write,
                                        __moonbit_time_unstable.now
exports                               → memory, eval_with_functions, describe_functions,
                                        dump_ast, disassemble, eval_checked, eval_expr,
                                        eval_jexl, describe_abi, _start
```

Without a `"wasm"` link profile the same build emits **259 B** (exports dropped
by DCE) — the export list, not the backend, is what makes the artifact real.

Round trip from a plain host (no js-string, no GC, `DataView` only):

| Input | Output |
| --- | --- |
| `dump_ast("1 + 2")` | `bin(+,int:1,int:2)` |
| `eval_expr("a * 2 + 1", "{\"a\": 20}", "vm")` | `41` |
| `eval_checked("1 + \"a\"", "{}", "walk")` | `{"$error":"invalid operation: + (mismatched types int and string) (1:3)…"}` |
| `describe_abi()` | full manifest, 967 code units |

String layout, measured: `u32` character count at `ptr - 4`, UTF-16LE from
`ptr`, `0x0000` terminator. Populated host-side, the engine accepted it as an
argument; produced engine-side, the host read it back correctly.

### A.3 Per-call cost on the 0.4.1 js-string artifact

```
eval_expr × 1000, 2-field env            →  15.2 ms total  (0.015 ms/call)
eval_with_functions × 1000, 2 functions  →  16.3 ms total  (0.016 ms/call)
eval_with_functions × 200, 200 functions → 95.0 ms total  (0.475 ms/call)
eval_expr × 200                          →  0.8 ms total  (0.004 ms/call)
                                             → 106× the plain-eval cost
```

### A.4 Adversarial inputs (existing artifact, no traps)

| Input | Result |
| --- | --- |
| 50k nested parens | `{"$error":"parse error at 1:334: expression is too deeply nested"}` |
| 50k nested arrays | same class of error |
| 50k-term `1+1+…` | `{"$error":"parse error at 1:1: expression is too deeply nested"}` |
| 2 MB env string | evaluates normally |

The engine does not trap on any probed input. That property is worth a
conformance case (P0.2) rather than a paragraph of prose, since a trap costs the
host its whole instance.

## Appendix B — deliberately out of scope

- **Host callbacks / `$host(name, args)` generalisation.** 0001 §3, 0002 §5, and
  0002's mooncry spike already settled this: the hashing case is solved natively,
  and the determinism cost of a general channel is not worth paying.
- **Batch evaluation API.** A session plus a host-side loop covers it; a separate
  export would be a second way to do the same thing.
- **`wasm-opt` / size budget.** 605 KB and 740 KB are acceptable for a rules
  engine; revisit only if a host asks.
- **Threads, multi-instance sharing, streaming.** The engine is synchronous and
  instance-scoped; nothing here changes that.
