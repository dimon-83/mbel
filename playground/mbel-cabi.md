# mbel C-ABI artifact — layout contract

Applies to `playground/mbel-cabi.wasm`, built from the same source as
`playground/mbel.wasm` with `moon build --target wasm --release`. The
manifest (`playground/mbel.abi.json`, artifact entry
`callingConvention: "mbel-cabi"`) describes this contract too; this file is
the prose version. Verified by `node tools/check_abi.mjs --cabi`.

The artifact targets WebAssembly MVP: no GC proposal, no js-string
builtins, no reference types. Any host that can instantiate a core-module
wasm binary can embed it (wasmtime, wasmer, WAMR, browsers, Python, Rust,
C/C++, ...). Strings are UTF-16LE end to end, matching the engine's native
representation.

## Module shape

- **Exports.** `memory` plus the 16 manifest functions and `_start`. The
  `_start` function is in the start section and runs at instantiation;
  hosts must not call it again.
- **Imports (both required).**
  - `wasi_snapshot_preview1.fd_write` — stub is fine (`() => 0`) unless
    you want engine panics on stderr.
  - `__moonbit_time_unstable.now` — `() -> i64`, Unix milliseconds. A
    constant is acceptable; nothing in mbel depends on it advancing.

## String convention (both directions)

Every `String` parameter is **one `i32` pointer**; every `String` result
is **one `i32` pointer**. The pointed-to layout is self-described by the
exported `abi_layout()` function:

```json
{"stringEncoding":"utf16le","lengthPrefix":"u32","headerOffset":-4,"terminator":2}
```

Concretely, at pointer `p`:

| offset   | size        | content                                  |
| -------- | ----------- | ---------------------------------------- |
| `p - 4`  | 4 bytes     | `u32` little-endian **character count**  |
| `p`      | `2 * n`     | UTF-16LE code units                      |
| `p+2n`   | 4 bytes     | two NUL code units (terminator)          |

Reading a returned string: take `n = u32(p - 4)`, decode `2n` bytes at
`p`, **copy out** before the next call. Writing an input string: build the
header + data + terminator yourself.

## Linear memory ownership (the one real trap)

The MoonBit runtime owns the **entire** linear memory and allocates with
an upward-moving bump pointer that starts right after the static data.
Consequences for a host:

1. **Reserve scratch by growing memory**, e.g. `memory.grow(4)` pages, and
   build input strings there. Keep every header (`p - 4`) inside the
   scratch region — the first string must not start at the very first byte
   of the grown area, or its header lands in engine-owned memory.
2. **The engine may overwrite any host-written region**, at any time
   between and during calls: the bump pointer walks straight through
   scratch space as it allocates. Therefore **re-write every input string
   immediately before every call**; treat a written string as valid only
   until the next engine allocation.
3. **Copy output strings out immediately** after the call returns, before
   anything else runs.
4. Never write into memory below the scratch region you grew; the engine
   considered it its own heap the moment the module was instantiated.

With that discipline the artifact is safe to call in a loop: the engine
never traps on host-provided strings, and results are deterministic.

## Calling patterns

Stateless evaluation (each call builds and drops one engine instance):

```
eval_expr(expr, env, engine)            // "walk" | "vm"
eval_checked(expr, env, engine)         // bodies/arity checked, errors early
eval_with_limits(expr, env, engine, limits_json)
eval_with_functions(code, env, funcs_json, mode, engine)
```

Session evaluation (register once, evaluate many times — amortises
function parsing/registration):

```
create_session(funcs_json, mode, engine, defaults_json) -> {"handle":"s-1",...}
eval_session(handle, expr, env)
describe_session(handle) -> {"handle","mode","engine","functions":[...],"limits":{...}}
configure_session(handle, limits_json)   // lowering only, see below
release_session(handle)
```

Introspection and diagnostics:

```
describe_abi()  -> the manifest  |  abi_layout() -> the string convention
dump_ast(source) | disassemble(source, env)
```

## Errors

Every failure returns the envelope from the manifest's `errorEnvelope`:

```json
{"$error":"message","$code":"CHECK_TYPE","$pos":{"line":1,"col":3}}
```

`$code` is one of the manifest's `errorCodes`; `$pos` appears for parse
and checked-mode errors. Hosts should switch on `$code`, not on message
text.

## Budgets

`limits_json` accepts `maxNodes`, `maxDepth`, `maxSteps` (non-negative
`i32`, `0` disables the guard) and `allowRaise` (boolean). Without
`allowRaise` a request may only lower a budget relative to the compiled
default; `configure_session` applies the same rule to a live session.
Exhausting a budget yields `$code: "RUNTIME_BUDGET"`.
