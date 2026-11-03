# Proposal: first-class expression-defined functions for stateless embedders

- **Status:** Draft
- **Date:** 2026-11-02
- **Target:** 0.4.x
- **Author:** external embedder (trend / modu integration)
- **Related:** `engine/userfuncs.mbt`, `playground/web/web.mbt`, `docs/en/functions.md`, `AGENTS.md` (Playground / WASM)

## TL;DR

MBEL **already supports** expression-defined functions: `Engine::add_expression_functions`,
`user_function_params`, the wasm exports `eval_with_functions` and `describe_functions`,
and a versioned functions-file format. This proposal is **not** a request to add UDFs.

It is a request to finish the **embedder contract** so a stateless wasm host can use the
existing capability safely and efficiently:

1. a machine-readable ABI manifest (hosts currently miss two of the seven exports);
2. a compiled function-set handle (today every call re-parses and re-registers every function);
3. checked mode that actually checks function bodies, names, and arity;
4. budget continuity across user-function calls (today budgets reset per call);
5. strict registration and lexical binding (today a functions file may silently shadow builtins);
6. structured error codes and function metadata;
7. reproducible wasm artifacts with checksums.

## Minimum viable path (and what is *not* required)

Nothing in P0–P7 is needed to **evaluate** a functions file: a host can call
`eval_with_functions` today. The split matters for sequencing:

| Milestone | MBEL change? | What it buys |
| --- | --- | --- |
| **M0 — use it now** | **No** | A host loads/persists the functions JSON and passes it on every call. For trend, the missing work is on the modu side: load `.modu/logic/functions.json`, pass it to the kernel, validate against it. |
| **M1 — discoverable + verifiable** | Yes, small | P0 (ABI manifest) + P2 (checked bodies/arity). This is the smallest set that makes `modu check` trustworthy. |
| **M2 — scale + security** | Yes, medium | P1 (compiled function set) + P3 (shared budget) + P4 (strict/lexical). |
| **M3 — polish** | Yes, small | P5–P7 (error codes, metadata, reproducible artifacts). |

So the proposal is not a blocker for trend. It is a request to close the gap between
"the feature exists" and "an embedder can use it safely at scale".

## 1. What already exists

| Capability | Where | Status |
| --- | --- | --- |
| `UserFunctionDef { name, params?, body }` | `engine/userfuncs.mbt` | shipped in 0.3.2 |
| `Engine::add_expression_functions(defs, defaults)` | `engine/userfuncs.mbt:397` | shipped |
| `user_function_params(name, body)` | `engine/userfuncs.mbt:143` | shipped |
| Atomic validation, 256-level recursion cap | `engine/userfuncs.mbt` | shipped |
| Functions file v1 `{version, functions, env?}` | `docs/en/functions.md` | shipped |
| `eval_with_functions(code, env, funcs_json, mode, engine)` | `playground/web/web.mbt:429` | shipped |
| `describe_functions(funcs_json)` | `playground/web/web.mbt:386` | shipped |
| Wasm exports in 0.3.7 | `playground/mbel.wasm`, modu's vendored wasm | present |

The actual exports of the 0.3.7 artifact are:

```
eval_with_functions, describe_functions, dump_ast, disassemble,
eval_checked, eval_expr, eval_jexl, _start
```

So the language and the wasm already expose the feature. The gap is in how an embedder
discovers, compiles, validates, and budgets it.

## 2. Why this matters: the trend / modu case

The trend project is a pure configuration application evaluated by modu. It has:

- **32** three-valued helper functions in `.modu/logic/functions.json` (11,210 B);
- **67** `RuleSpec`s (14 main + 53 clauses) in `.modu/rules.json`;
- **1.07 MiB** of rules after macro-inlining those helpers (`1,122,897 B`);
- one expanded clause reaching **49,808 characters**;
- a 5,724-row verdict baseline used for semantic parity checks.

The current workaround is build-time macro expansion: a retired script inlines every
function body into every rule. The result is correct, but it has three costs:

1. **Readability and review:** a rule is no longer the expression a human wrote; it is a
   fully expanded tree. The readable source lives in a separate file that the runtime
   never loads.
2. **Drift:** `functions.json` and `rules.json` can disagree. `modu check` rejects any
   un-inlined UDF ("MBEL unknown function"), so the only way to use a function is to
   regenerate 1 MiB of JSON.
3. **Validation:** there is no single place to type-check or arity-check the helper
   bodies; the expansion is opaque to the host.

This is exactly the use case expression-defined functions were designed for. The
remaining blocker is that the embedder API is one-shot, stringly typed, and not
discoverable.

## 3. Goals and non-goals

### Goals

- Let a host load a functions file once, then evaluate many expressions against it.
- Make checked mode cover the whole unit of code (main expression **and** function bodies),
  including unknown names and arity.
- Keep evaluation pure, deterministic, sandboxed, and budgeted.
- Preserve the existing functions-file format and the existing exports.
- Make the wasm ABI discoverable and reproducible.

### Non-goals

- Host callbacks / FFI / reflection. Functions remain pure expressions.
- A general-purpose module system (imports, namespaces, mutable state).
- Changing classic-dialect (legacy) semantics.
- Removing `eval_with_functions`; it should remain the one-shot convenience form.

## 4. Proposal

### P0. Publish a machine-readable ABI manifest

Ship `mbel.abi.json` next to the wasm (and optionally expose `describe_abi()`):

```json
{
  "abiVersion": 1,
  "engineVersion": "0.3.7",
  "functionsFileVersion": 1,
  "exports": [
    { "name": "eval_expr", "params": ["expr", "env", "engine"], "returns": "json" },
    { "name": "eval_with_functions", "params": ["code", "env", "funcs_json", "mode", "engine"], "returns": "json" },
    { "name": "describe_functions", "params": ["funcs_json"], "returns": "json" }
  ],
  "errorEnvelope": { "message": "$error", "code": "$code" },
  "limits": { "maxNodes": 10000, "maxDepth": 10000, "maxSteps": 1000000, "userfnDepth": 256 }
}
```

Add a CI check that the manifest's export names and kinds equal
`WebAssembly.Module.exports(wasm)`; signatures are asserted by a conformance test. This
is how a host wrapper knows that `eval_with_functions` exists; today a wrapper can
reasonably declare only the three exports it knows and silently lose the capability.

### P1. Add a compiled function-set handle

Current `eval_with_functions` creates a fresh engine and re-parses/re-registers every
function on every call. That is fine for a playground, but a rules engine may evaluate
dozens of expressions per row over thousands of rows. For trend's 12 main rules over
5,724 rows, that is ~68k calls and ~68k re-registrations of the same 32 functions.

Proposed exports (additive):

```
compile_functions(funcs_json) -> {"handle":"fs-1","functions":[...]}
eval_with_function_set(handle, code, env, mode, engine) -> result
describe_function_set(handle) -> [...]
release_function_set(handle) -> {"ok":true}
```

Semantics:

- `compile_functions` parses, validates, and compiles bodies once; atomic on failure.
- The handle is immutable and scoped to the wasm instance.
- Cap the number of live sets (e.g. 16) and their total memory; return a structured
  error when exceeded.
- `release_function_set` frees the set; using a released handle is an error.
- `eval_with_functions` remains as `compile + eval + release` sugar, or is documented
  as the one-shot path.
- Alternatively, an LRU form `eval_with_functions_cached(code, env, funcs_json,
  cache_key, mode, engine)` is acceptable if handles are undesirable in the ABI.

Acceptance: the two paths produce identical values and errors on the function corpus,
on Walk and Vm, on all three targets.

### P2. Make checked mode cover function bodies and calls

Today `mode="checked"` type-checks the main expression and checks its identifiers, but
function bodies are only compiled and constant-folded. A body like `1 + "a"` is accepted
at registration and fails only at evaluation. Arity is also unchecked: missing arguments
silently fall back to same-named env keys, and extra arguments are ignored.

In `mode="checked"`:

1. Type-check every body with the same checker used for the main expression
   (`compile_expr_checked_limited`).
2. Build the symbol table first: all function names in the set + their params + builtins
   + aggregates. Bodies may forward-reference other functions in the same set (the
   runtime already supports mutual references).
3. Check call sites: unknown function, arity (see below), and argument types when the
   checker can infer them.
4. Report errors with the function name and `functions[i].body (L:C)` position.

Arity needs an explicit contract:

- explicit `params` → exact arity;
- omitted `params` → auto-extracted list, exact arity;
- optional parameters → declare them; do not infer "optional" from the env fallback.

Recommendation: add `binding: "lexical" | "env"` to the functions file. `"env"` keeps
today's fallback; `"lexical"` makes a missing argument an error. Checked mode should
default to `"lexical"` (or require an explicit `"env"`), so a missing parameter cannot
silently pick up a same-named value from the environment. This matters for three-valued
logic: a helper such as `tri_eq(v, w)` must not accidentally read `v` from the env when
the caller forgot to pass it.

### P3. Carry the budget across user-function calls

`docs/en/functions.md` states that depth/step budgets restart per call; recursion is
bounded only by the 256-level counter. A chain of 256 calls can therefore consume up to
256 × `max_steps`, which weakens the DoS guarantee for untrusted functions files.

Proposal: carry a shared budget cell through the user-function call chain. Each nested
call draws from the caller's remaining `max_steps`/`max_depth`; the 256-level recursion
cap stays. Expose `userfn_calls` and `userfn_steps` in `budget_stats()`.

Keep the existing budget messages contract-stable; add detail through stats or a new
structured code, not by editing the message text.

### P4. Strict registration and lexical binding

`add_expression_functions` currently allows ordinary builtin names to be overridden via
upsert. For a functions file loaded from disk (or from a user), silent shadowing of
`len`, `sum`, `contains`, etc. is a supply-chain hazard and changes semantics without
any signal.

Add a `strict` option (on the file or the call):

- reject overriding builtins, transforms, and aggregates;
- reject duplicate names across registration batches;
- return the conflicting names in the error.

Parameter names are lexical and may legitimately shadow a builtin inside the body; the
conflict rule applies to function names, not parameter names.

Default should preserve current behavior for compatibility; `eval_with_functions` may
opt into strict mode, and `compile_functions` should recommend/default to strict.

### P5. Structured error codes

Errors are currently `{"$error": "..."}` strings. Hosts cannot reliably map them to
validation UI, retries, or logs. Add an optional `$code` alongside `$error`, keeping the
message text unchanged:

```
FUNC_FILE_JSON, FUNC_FILE_VERSION, FUNC_NAME, FUNC_PARAM, FUNC_DUPLICATE,
FUNC_CONFLICT, FUNC_BODY_PARSE, FUNC_BODY_TYPE, FUNC_UNKNOWN, FUNC_ARITY,
FUNC_RECURSION, FUNC_BUDGET, FUNC_HANDLE
```

Existing hosts ignore `$code`; new hosts can branch on it. This also lets `modu check`
distinguish "unknown function because it was not registered" from "unknown name in the
environment".

### P6. Function metadata and dependency reporting

`describe_functions` already returns `{name, params, description}`. Extend it (and
`describe_function_set`) with:

- `requiredParams` / `optionalParams`;
- `captures`: free identifiers not bound by params (today they are auto-extracted as
  params when `params` is omitted; if explicit params are given, captures are the
  residual free names);
- `dependsOn`: other user functions called by the body;
- `recursive`: whether the dependency graph has a cycle;
- `bodyHash`: a stable hash for cache keys and audit.

Optionally add `dump_function_ast(name)` for host-side static analysis. This is useful
for a rule validator that wants to show "this rule depends on these helpers".

### P7. Reproducible wasm artifacts

Publish, per release:

- `mbel-<version>.wasm` with sha256;
- `mbel.abi.json` (P0);
- the functions-file schema version;
- a build recipe (the `moon build --target wasm-gc --release` + copy step already exists
  in `AGENTS.md`).

The current `playground/mbel.wasm` is dated 2026-09-09 while the module is 0.3.7; a host
cannot tell from the filename which ABI it contains. A checksum and manifest remove that
ambiguity. Also state clearly that `playground/mbel.wasm` is a release artifact, not a
stale playground leftover.

## 5. API sketch

```jsonc
// compile_functions input
{
  "version": 1,
  "strict": true,
  "binding": "lexical",
  "functions": [
    { "name": "tri_eq", "params": ["v", "w"], "body": "v == nil ? nil : (v == w)" },
    { "name": "and3",   "params": ["a", "b"], "body": "a == false ? false : (b == false ? false : (a == nil || b == nil ? nil : true))" }
  ]
}

// compile_functions success
{
  "handle": "fs-1",
  "functions": [
    { "name": "tri_eq", "params": ["v", "w"], "requiredParams": ["v", "w"], "dependsOn": [] },
    { "name": "and3",   "params": ["a", "b"], "requiredParams": ["a", "b"], "dependsOn": [] }
  ]
}

// compile_functions failure (atomic: nothing registered)
{
  "$error": "function \"and3\": unknown name \"b\" (2:14)",
  "$code": "FUNC_BODY_TYPE"
}

// evaluation
eval_with_function_set("fs-1", "and3(tri_eq(x, 1), true)", "{\"x\":1}", "checked", "walk")
```

## 6. Semantics and compatibility

- **Additive ABI.** The existing `eval_expr`, `eval_checked`, `eval_jexl`, `dump_ast`,
  `disassemble` exports keep their signatures and behavior.
- **Functions file v1 stays valid.** New fields (`strict`, `binding`, optional params)
  are optional; absent fields keep current behavior.
- **One-shot API stays.** `eval_with_functions` remains for playgrounds and small hosts.
- **Name resolution.** In non-strict mode, keep upsert semantics. In strict mode, a user
  function may not shadow a builtin/transform/aggregate, and duplicate names are errors.
- **Evaluation.** Bodies remain pure expressions; no host calls, no mutable state.
  Call-by-value, with `nil` propagation unchanged.
- **Budgets.** The recursion cap remains 256; the step/depth budget becomes shared across
  the call chain (P3). This is a behavior change only for pathological chains, and it is
  a security improvement.
- **Handles.** A handle is instance-scoped and invalid after `release` or wasm instance
  teardown. Document the lifetime explicitly.

## 7. Security

- A functions file is code. Loading one is equivalent to evaluating an expression; the
  docs already say this. Keep the warning prominent.
- The sandbox remains pure: no FFI, no reflection, no host access.
- New guarantees: shared budget across calls, strict name resolution, capped live
  function sets, structured errors that do not leak internals.
- Do not add host callbacks to the wasm ABI.

## 8. Acceptance criteria

1. `mbel.abi.json` matches `WebAssembly.Module.exports(wasm)` in CI.
2. `eval_with_functions` and `eval_with_function_set` produce identical values and error
   messages on the function corpus, on Walk and Vm, on wasm-gc/js/native.
3. Trend corpus: 32 functions / 67 rules, 100% semantic parity with the inline baseline
   over the 5,724-row verdict set; rules can reference helpers without expansion;
   `rules.json` size drops by roughly the expansion factor (target: from ~1.07 MiB to
   the size of the source expressions + function file).
4. Checked mode rejects: a body type error, an unknown name in a body, an arity mismatch
   at a call site, and an unknown function.
5. A 256-level user-function chain cannot exceed the configured total step budget.
6. Strict mode rejects a function named `len` and reports `FUNC_CONFLICT`.
7. A JS/TS embedding example loads a functions file once, evaluates with a handle, and
   releases it.

## 9. Alternatives considered

- **Status quo (host-side macro expansion).** Works and is already deployed in trend, but
  it produces ~100× larger config, hides the helper source from the runtime, and makes
  checked mode impossible for helper bodies.
- **A host preprocessor.** Same drawbacks; every host reimplements it.
- **Host callbacks / FFI for functions.** Breaks the pure sandbox, is not portable to
  wasm, and makes results non-deterministic across hosts.
- **A language-level `fn`/module system.** Much larger surface; the expression-defined
  function feature already covers the need.

## 10. Open questions

1. Handle API vs. hash-keyed cache: which fits the project's stateless-wasm philosophy
   better? A handle is explicit but introduces instance state; a cache is implicit but
   needs eviction rules.
2. Should `strict` / `lexical` become the default in 0.4, with an explicit opt-out for
   compatibility?
3. Optional-parameter syntax: `optional: ["x"]` plus a default expression, or a separate
   `defaults` object per function? Avoid overloading the existing env fallback.
4. Error-code naming and whether `$code` should be stable API or diagnostic-only.
5. Should `dump_ast` accept a function set so hosts can analyze helper bodies without
   re-parsing? (Lower priority.)

## Appendix A — trend numbers used above

| Metric | Value |
| --- | --- |
| Helper functions | 32 |
| `functions.json` size | 11,210 B |
| RuleSpecs | 67 (14 main + 53 clauses) |
| `rules.json` size after inlining | 1,122,897 B |
| Largest expanded branch | 49,808 chars |
| Verdict baseline rows | 5,724 |

## Appendix B — current wasm exports (0.3.7)

```
eval_with_functions, describe_functions, dump_ast, disassemble,
eval_checked, eval_expr, eval_jexl, _start
```

The modu host wrapper currently declares only `eval_expr`, `eval_checked`, and
`dump_ast`; the two function exports are present in the artifact but invisible to the
host. This is the concrete integration failure the ABI manifest (P0) would prevent.
