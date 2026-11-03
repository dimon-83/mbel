//! mbel C-ABI embedding example for Rust via wasmtime.
//!
//! Run from this directory:  cargo run --release
//! (builds against ../../playground/mbel-cabi.wasm)
//!
//! The C-ABI contract is in playground/mbel-cabi.md; the two rules that
//! matter: build input strings in memory you grew yourself, and re-write
//! them immediately before every call (the engine bump-allocates over all
//! of linear memory).
//!
//! Results are printed as raw JSON so the example needs no serde.

use std::path::PathBuf;

use wasmtime::{Engine, FuncType, Linker, Module, Store, Val, ValType};

/// Reserve scratch, write an input string, return its pointer.
/// Layout: u32 char count at ptr-4, UTF-16LE data, two NUL code units.
fn write_str(store: &mut Store<()>, memory: &wasmtime::Memory, cursor: &mut usize, text: &str) -> i32 {
    let ptr = *cursor;
    let mut bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
    bytes.extend_from_slice(&[0, 0, 0, 0]); // terminator: two NUL units
    memory.write(&mut *store, ptr, &bytes).expect("scratch write");
    memory
        .write(store, ptr - 4, &(text.chars().count() as u32).to_le_bytes())
        .expect("header write");
    *cursor = ptr + bytes.len();
    *cursor += (8 - (*cursor % 8)) % 8; // keep 8-byte alignment
    ptr as i32
}

/// Decode a returned string: u32 char count at ptr-4, UTF-16LE at ptr.
fn read_str(store: &mut Store<()>, memory: &wasmtime::Memory, ptr: i32) -> String {
    let ptr = ptr as u64 as usize;
    let mut len_bytes = [0u8; 4];
    memory.read(&mut *store, ptr - 4, &mut len_bytes).expect("header read");
    let n = u32::from_le_bytes(len_bytes) as usize;
    let mut raw = vec![0u8; 2 * n];
    memory.read(&mut *store, ptr, &mut raw).expect("data read");    let units: Vec<u16> = raw
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&units)
}

/// One call: re-write every argument, invoke, decode the result.
fn call(
    store: &mut Store<()>,
    memory: &wasmtime::Memory,
    func: &wasmtime::Func,
    args: &[&str],
    cursor: &mut usize,
) -> String {
    let params: Vec<Val> = args
        .iter()
        .map(|a| Val::I32(write_str(store, memory, cursor, a)))
        .collect();
    let mut result = [Val::I32(0)];
    func.call(&mut *store, &params, &mut result)
        .expect("mbel never traps on host strings");
    read_str(store, memory, result[0].i32().expect("string return"))
}

fn main() -> anyhow::Result<()> {
    let wasm =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../playground/mbel-cabi.wasm");
    let engine = Engine::default();
    let module = Module::from_file(&engine, &wasm)?;
    let mut store = Store::new(&engine, ());
    let mut linker = Linker::new(&engine);

    // wasi_snapshot_preview1.fd_write: a stub is enough (engine panics on
    // stderr are optional). Real WASI also works via the `wasmtime-wasi` crate.
    linker.func_wrap(
        "wasi_snapshot_preview1",
        "fd_write",
        |_fd: i32, _iov: i32, _iovcnt: i32, _nwritten: i32| -> i32 { 0 },
    )?;
    // __moonbit_time_unstable.now: () -> i64 Unix ms; a constant is fine.
    linker.func_new(
        "__moonbit_time_unstable",
        "now",
        FuncType::new(&engine, vec![], vec![ValType::I64]),
        |_caller, _params, results: &mut [Val]| -> Result<(), wasmtime::Error> {
            results[0] = Val::I64(0);
            Ok(())
        },
    )?;

    let instance = linker.instantiate(&mut store, &module)?;
    let memory = instance
        .get_memory(&mut store, "memory")
        .expect("mbel exports memory");
    let eval_expr = instance.get_func(&mut store, "eval_expr").expect("export");
    let eval_checked = instance.get_func(&mut store, "eval_checked").expect("export");
    let abi_layout = instance.get_func(&mut store, "abi_layout").expect("export");
    let create_session = instance.get_func(&mut store, "create_session").expect("export");
    let eval_session = instance.get_func(&mut store, "eval_session").expect("export");
    let configure_session = instance.get_func(&mut store, "configure_session").expect("export");
    let release_session = instance.get_func(&mut store, "release_session").expect("export");

    // One scratch reservation; inputs are re-written before every call.
    let scratch_page = memory.grow(&mut store, 4)?;
    let mut cursor = (scratch_page * 65536 + 8) as usize;

    // 1. introspection
    println!("string convention: {}", call(&mut store, &memory, &abi_layout, &[], &mut cursor));

    // 2. stateless evaluation
    println!(
        "1 + 2 = {}",
        call(&mut store, &memory, &eval_expr, &["1 + 2", "{}", "walk"], &mut cursor)
    );

    // 3. errors carry $code / $pos
    println!(
        "typed error: {}",
        call(&mut store, &memory, &eval_checked, &["1 + \"a\"", "{}", "walk"], &mut cursor)
    );

    // 4. sessions: register once, evaluate many times
    let funcs = r#"{"version":1,"functions":[{"name":"fee","params":["amount"],"body":"amount * 2 + 1"}]}"#;
    let session = call(
        &mut store,
        &memory,
        &create_session,
        &[funcs, "checked", "walk", ""],
        &mut cursor,
    );
    // handle extraction without serde: `"handle":"s-N"` is stable and quoted
    let handle = session
        .split(r#""handle":""#)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .expect("create_session returned a handle")
        .to_string();
    println!("session: {} (handle {})", session, handle);

    for amount in [20, 50, 80] {
        // env is data: re-write it per call
        let env = format!(r#"{{"amount":{amount}}}"#);
        println!(
            "fee({amount}) = {}",
            call(&mut store, &memory, &eval_session, &[&handle, "fee(amount)", &env], &mut cursor)
        );
    }

    // 5. budgets: lowering only
    println!(
        "configure: {}",
        call(&mut store, &memory, &configure_session, &[&handle, r#"{"maxSteps":1000}"#], &mut cursor)
    );

    println!("release: {}", call(&mut store, &memory, &release_session, &[&handle], &mut cursor));
    println!(
        "after release: {}",
        call(&mut store, &memory, &eval_session, &[&handle, "fee(1)", r#"{"amount":1}"#], &mut cursor)
    );

    Ok(())
}
