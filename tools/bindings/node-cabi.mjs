#!/usr/bin/env node
// mbel C-ABI embedding example for Node.js (plain Node >= 16, no options).
//
// Run from the repo root:  node tools/bindings/node-cabi.mjs
//
// See playground/mbel-cabi.md for the full contract. The two rules that
// matter: build input strings in memory you grew yourself, and re-write
// them immediately before every call (the engine bump-allocates over all
// of linear memory).

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const wasmPath = resolve(dirname(fileURLToPath(import.meta.url)), '../../playground/mbel-cabi.wasm');

const bytes = readFileSync(wasmPath);
const module = await WebAssembly.compile(bytes);
const instance = await WebAssembly.instantiate(module, {
  wasi_snapshot_preview1: { fd_write: () => 0 },
  __moonbit_time_unstable: { now: () => BigInt(Date.now()) },
});
const ex = instance.exports;
const mem = ex.memory;
const decoder = new TextDecoder('utf-16le');

function readStr(ptr) {
  const n = new DataView(mem.buffer).getUint32(ptr - 4, true);
  return decoder.decode(new Uint8Array(mem.buffer, ptr, n * 2));
}

// One scratch reservation for the whole program; every input string is
// re-written into it right before the call that uses it.
const scratchPage = mem.grow(4);
let cursor = scratchPage * 65536 + 8;

function writeStr(text) {
  const ptr = cursor;
  const units = new Uint16Array(mem.buffer, ptr, text.length + 2);
  for (let i = 0; i < text.length; i++) units[i] = text.charCodeAt(i);
  units[text.length] = 0;
  units[text.length + 1] = 0;
  new DataView(mem.buffer).setUint32(ptr - 4, text.length, true);
  cursor = ptr + (text.length + 2) * 2;
  if (cursor % 8) cursor += 8 - (cursor % 8);
  return ptr;
}

function call(name, args) {
  return readStr(ex[name](...args.map(writeStr)));
}

// 1. introspection
const layout = JSON.parse(call('abi_layout', []));
console.log('string convention:', JSON.stringify(layout));

// 2. stateless evaluation
console.log('1 + 2 =', call('eval_expr', ['1 + 2', '{}', 'walk']));

// 3. errors carry $code / $pos
const bad = JSON.parse(call('eval_checked', ['1 + "a"', '{}', 'walk']));
console.log('typed error:', bad.$code, bad.$error, JSON.stringify(bad.$pos));

// 4. sessions: register once, evaluate many times
const funcs = JSON.stringify({
  version: 1,
  functions: [{ name: 'fee', params: ['amount'], body: 'amount * 2 + 1' }],
});
const session = JSON.parse(call('create_session', [funcs, 'checked', 'walk', '']));
console.log('session:', session.handle, session.functions);

const env = JSON.stringify({ amount: 20 });
for (const amount of [20, 50, 80]) {
  // env is data: re-write it per call
  console.log(`fee(${amount}) =`, call('eval_session', [session.handle, 'fee(amount)', JSON.stringify({ amount })]));
}

// 5. budgets: lowering only
console.log('configure:', call('configure_session', [session.handle, '{"maxSteps":1000}']));

console.log('release:', call('release_session', [session.handle]));
console.log('after release:', call('eval_session', [session.handle, 'fee(1)', env]));
