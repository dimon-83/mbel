#!/usr/bin/env python3
"""mbel C-ABI embedding example for Python via wasmtime-py.

Install:  pip install wasmtime
Run:      python3 tools/bindings/python-wasmtime.py   (from the repo root)

The C-ABI contract is in playground/mbel-cabi.md; the two rules that
matter: build input strings in memory you grew yourself, and re-write
them immediately before every call (the engine bump-allocates over all
of linear memory).
"""

import json
from pathlib import Path

import wasmtime

WASM = Path(__file__).resolve().parents[2] / "playground" / "mbel-cabi.wasm"

engine = wasmtime.Engine()
module = wasmtime.Module.from_file(engine, str(WASM))
store = wasmtime.Store(engine)
linker = wasmtime.Linker(engine)
# WASI provides wasi_snapshot_preview1.fd_write; only the stub is needed.
wasi = wasmtime.WasiConfig()
wasi.inherit_stdout()
wasi.inherit_stderr()
store.set_wasi(wasi)
linker.define_wasi()

# The engine asks for a wall-clock source (i64, Unix ms); a constant is fine.
linker.define(
    store,
    "__moonbit_time_unstable",
    "now",
    wasmtime.Func(store, wasmtime.FuncType([], [wasmtime.ValType.i64()]), lambda: 0),
)

instance = linker.instantiate(store, module)
memory = instance.exports(store)["memory"]
exports = instance.exports(store)


def read_str(ptr: int) -> str:
    """Decode a returned string: u32 char count at ptr-4, UTF-16LE at ptr."""
    n = int.from_bytes(memory.read(store, ptr - 4, ptr), "little")
    raw = memory.read(store, ptr, ptr + 2 * n)
    return raw.decode("utf-16-le")


# One scratch reservation; every input string is re-written before each call.
scratch_page = memory.grow(store, 4)
assert scratch_page != -1
_cursor = scratch_page * 65536 + 8


def write_str(text: str) -> int:
    """Encode text as the engine expects: header, UTF-16LE data, NUL pair."""
    global _cursor
    ptr = _cursor
    units = text.encode("utf-16-le") + b"\x00\x00\x00\x00"
    memory.write(store, units, ptr)
    memory.write(store, len(text).to_bytes(4, "little"), ptr - 4)
    _cursor = ptr + len(units)
    if _cursor % 8:
        _cursor += 8 - (_cursor % 8)
    return ptr


def call(name: str, *args: str) -> str:
    fn = exports[name]
    result = fn(store, *[write_str(a) for a in args])
    return read_str(result)


if __name__ == "__main__":
    # 1. introspection
    print("string convention:", call("abi_layout"))

    # 2. stateless evaluation
    print("1 + 2 =", call("eval_expr", "1 + 2", "{}", "walk"))

    # 3. errors carry $code / $pos
    bad = json.loads(call("eval_checked", '1 + "a"', "{}", "walk"))
    print("typed error:", bad["$code"], bad["$error"], bad.get("$pos"))

    # 4. sessions: register once, evaluate many times
    funcs = json.dumps(
        {
            "version": 1,
            "functions": [
                {"name": "fee", "params": ["amount"], "body": "amount * 2 + 1"}
            ],
        }
    )
    session = json.loads(call("create_session", funcs, "checked", "walk", ""))
    print("session:", session["handle"], session["functions"])

    for amount in (20, 50, 80):
        # env is data: re-write it per call
        env = json.dumps({"amount": amount})
        print(
            f"fee({amount}) =",
            call("eval_session", session["handle"], "fee(amount)", env),
        )

    # 5. budgets: lowering only
    print("configure:", call("configure_session", session["handle"], '{"maxSteps":1000}'))

    print("release:", call("release_session", session["handle"]))
    print(
        "after release:",
        call("eval_session", session["handle"], "fee(1)", '{"amount":1}'),
    )
