# Embedding mbel in a host application

mbel ships two wasm artifacts built from the same source and described by
one manifest, `playground/mbel.abi.json` (also returned at runtime by the
`describe_abi()` export). Pick by host capability; the exported functions
and their JSON behaviour are identical.

| | `playground/mbel.wasm` | `playground/mbel-cabi.wasm` |
| --- | --- | --- |
| target | wasm-gc | wasm (MVP) |
| calling convention | js-string builtins | `mbel-cabi` (this doc + `playground/mbel-cabi.md`) |
| strings | real JS strings | UTF-16LE pointers |
| host requirements | GC + js-string builtins proposals | WebAssembly MVP only |
| known-good hosts | Node >= 24, Chrome/Edge 130+, Firefox 134+, Safari 18.4+ | any MVP host (verified: Node, Python/wasmtime, Rust/wasmtime) |
| verification | `node tools/check_abi.mjs` | `node tools/check_abi.mjs --cabi` |

## Export surface (identical on both artifacts)

```
describe_abi()  abi_layout()
eval_expr(expr, env, engine)            eval_jexl / eval_checked / eval_with_limits
eval_with_functions(code, env, funcs, mode, engine)
create_session(funcs, mode, engine, defaults)  eval_session(handle, expr, env)
describe_session(handle)  configure_session(handle, limits)  release_session(handle)
describe_functions(funcs)  dump_ast(source)  disassemble(source, env)
```

All return JSON (a bare JSON value for successful expression evaluation,
otherwise an object). Every failure is the envelope

```json
{"$error":"message","$code":"CHECK_TYPE","$pos":{"line":1,"col":3}}
```

with `$code` from the manifest's `errorCodes` and `$pos` present for parse
and checked-mode errors. Switch on `$code`, never on message text.

## Loading `mbel.wasm` (JS hosts)

```js
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("mbel.wasm"),
  { __moonbit_time_unstable: { now: () => Date.now() } },
  { builtins: ["js-string"], importedStringConstants: "_" },
);
const out = JSON.parse(instance.exports.eval_expr("1 + 2", "{}", "walk"));
```

`playground/mbel.d.ts` types the full export surface. Run
`node tools/check_abi.mjs` against the artifact you ship: it verifies the
export set, cross-checks `engineVersion` against `moon.mod`, deep-compares
`describe_abi()` with the manifest file and smoke-calls every signature
shape, including a session lifecycle.

## Loading `mbel-cabi.wasm` (any host)

Full layout contract: `playground/mbel-cabi.md`. The essentials:

- **Imports.** `wasi_snapshot_preview1.fd_write` (stub ok) and
  `__moonbit_time_unstable.now` (`() -> i64` Unix ms, constant ok).
  `_start` is in the start section; it runs at instantiation.
- **Strings.** Each `String` parameter/result is one `i32` pointer:
  `u32` character count at `ptr - 4`, UTF-16LE data at `ptr`, two NUL
  code units after the data. `abi_layout()` reports this convention.
- **Linear memory.** The engine owns all of it and bump-allocates upward.
  Grow memory for scratch, build input strings there, and **re-write them
  immediately before every call**; copy results out immediately after the
  call. Never write into memory you did not grow yourself.
- **Errors, budgets, sessions** behave exactly as on the js-string
  artifact; `configure_session` and `eval_with_limits` accept
  `maxNodes` / `maxDepth` / `maxSteps` / `allowRaise`, and lowering only.

Runnable examples for three hosts live in `tools/bindings/` (Node,
Python + wasmtime, Rust + wasmtime).

## Versioning and compatibility policy

- `abiVersion` (currently `1`) changes only when the *calling convention*
  or the error envelope changes — a breaking event. Hosts should store the
  value returned by `describe_abi()` and refuse to run on a different major.
- `engineVersion` follows the crate version (SemVer). Within a major,
  fixes and features may extend the export surface or add `errorCodes`;
  existing exports keep their signature and semantics.
- New manifest keys may appear at any time; unknown keys are additive.
  `sessionLimit` and `limits` describe the compiled defaults of the
  artifact you loaded, not guarantees across versions.
- The functions-file format has its own `functionsFileVersion`; a session
  or functions file that fails to load yields `FUNCS_VERSION` rather than
  silent reinterpretation.
- Verify a shipped artifact with `tools/check_abi.mjs [--cabi]` in CI —
  it fails loudly if the wasm and the manifest drift apart.

## Security notes

- Evaluation is budgeted (`maxNodes` / `maxDepth` / `maxSteps`, defaults in
  the manifest); a budget hit returns `RUNTIME_BUDGET`, it does not trap.
- Hosts that take expressions from untrusted users should use
  `eval_with_limits` (or a session + `configure_session`) to lower the
  budgets below the defaults; raising requires `allowRaise: true`. The
  lowering rule compares against the compiled **default**, not the
  session's current value — if untrusted input can drive
  `configure_session`, enforce monotonicity on the host side.
- Sessions are capped (`sessionLimit`, default 16). Release handles when
  done; leaked handles surface as `HANDLE_LIMIT` on the next create.
