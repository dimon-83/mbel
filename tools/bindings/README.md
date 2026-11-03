# mbel bindings — runnable embedding examples

All three examples drive the **C-ABI artifact** (`playground/mbel-cabi.wasm`)
through the same script: introspect, evaluate statelessly, handle a typed
error, run a session lifecycle, lower a budget. The contract they follow is
in `playground/mbel-cabi.md`.

| example | host | run |
| --- | --- | --- |
| `node-cabi.mjs` | Node >= 16 (plain WebAssembly) | `node tools/bindings/node-cabi.mjs` |
| `python-wasmtime.py` | Python 3 + `wasmtime` | `pip install wasmtime && python3 tools/bindings/python-wasmtime.py` |
| `rust-wasmtime/` | Rust + `wasmtime` crate | `cd tools/bindings/rust-wasmtime && cargo run` |

For the **js-string artifact** (`playground/mbel.wasm`, wasm-gc) there is no
example here: on a capable host it needs no FFI at all — strings are real JS
strings. See `playground/mbel.d.ts` for the typed surface and
`docs/en/wasm-embedding.md` for the loading incantation.

CI checks both artifacts with `node tools/check_abi.mjs` and
`node tools/check_abi.mjs --cabi`.
