#!/usr/bin/env node
// Verifies the wasm ABI against playground/mbel.abi.json (P0).
//
// Checks, in order:
//   1. every export in the manifest exists in the wasm (and vice versa)
//      with the same kind;
//   2. manifest.engineVersion matches moon.mod;
//   3. describe_abi() returns the manifest (deep equality);
//   4. a smoke call per signature shape works (eval_expr / eval_checked /
//      describe_functions), so the declared params are not decorative.
//
// Usage: node tools/check_abi.mjs [--cabi] [wasm] [manifest]
//
// Default mode checks the wasm-gc artifact (js-string calling convention).
// With --cabi it checks the wasm (MVP) artifact instead: strings cross the
// boundary as UTF-16LE pointers (u32 char count at ptr-4, two NUL code
// units after the data), the module imports wasi_snapshot_preview1.fd_write
// and __moonbit_time_unstable.now, and _start runs at instantiation. The
// engine owns all of linear memory (bump allocator), so host-written input
// strings must be re-written immediately before every call.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const cabi = process.argv.includes('--cabi');
const positional = process.argv.slice(2).filter((a) => a !== '--cabi');
const wasmPath = positional[0]
  ? resolve(positional[0])
  : resolve(root, cabi ? 'playground/mbel-cabi.wasm' : 'playground/mbel.wasm');
const manifestPath = positional[1]
  ? resolve(positional[1])
  : resolve(root, 'playground/mbel.abi.json');

function fail(message) {
  console.error(`ABI check failed: ${message}`);
  process.exit(1);
}

function canon(value) {
  if (Array.isArray(value)) return value.map(canon);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((key) => [key, canon(value[key])]),
    );
  }
  return value;
}

const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));

const modSource = readFileSync(resolve(root, 'moon.mod'), 'utf8');
const versionMatch = modSource.match(/^\s*version\s*=\s*"([^"]+)"/m);
if (!versionMatch) fail('cannot read version from moon.mod');
if (manifest.engineVersion !== versionMatch[1]) {
  fail(
    `manifest engineVersion ${manifest.engineVersion} != moon.mod ${versionMatch[1]}`,
  );
}

for (const entry of manifest.exports) {
  if (entry.abi === false) continue;
  if (!Array.isArray(entry.params) || entry.returns !== 'json') {
    fail(`manifest entry ${entry.name} lacks params/returns`);
  }
}

const bytes = readFileSync(wasmPath);
let module;
try {
  module = await WebAssembly.compile(
    bytes,
    cabi
      ? {}
      : {
          builtins: ['js-string'],
          importedStringConstants: '_',
        },
  );
} catch (error) {
  fail(`cannot compile ${wasmPath}: ${error.message}`);
}

const actual = WebAssembly.Module.exports(module)
  .map((entry) => `${entry.name}:${entry.kind}`)
  .sort();
const expected = manifest.exports
  .map((entry) => `${entry.name}:${entry.kind}`)
  .sort();
if (cabi) {
  // The MVP artifact additionally exports memory and runs _start at
  // instantiation; every manifest function must be present with its kind.
  const actualSet = new Set(actual);
  for (const entry of expected) {
    if (!actualSet.has(entry)) {
      fail(`wasm is missing manifest export ${entry}`);
    }
  }
} else if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  fail(
    `wasm exports differ from manifest\n  wasm:     ${actual.join(', ')}\n  manifest: ${expected.join(', ')}`,
  );
}

if (!cabi) {
  await smokeJsString(manifest, module);
} else {
  await smokeCabi(manifest, module, wasmPath);
}

console.log(
  `ABI OK: ${wasmPath} matches ${manifestPath} (${manifest.exports.length} exports, engine ${manifest.engineVersion}${cabi ? ', C-ABI' : ''})`,
);

// ---------------------------------------------------------------------------
// wasm-gc (js-string) smoke calls
// ---------------------------------------------------------------------------

async function smokeJsString(manifest, module) {
  const instance = await WebAssembly.instantiate(module, {
    __moonbit_time_unstable: { now: () => 0n },
  });
  const exported = instance.exports;

  if (typeof exported.describe_abi !== 'function') {
    fail('wasm does not export describe_abi');
  }
  const described = JSON.parse(exported.describe_abi());
  if (JSON.stringify(canon(described)) !== JSON.stringify(canon(manifest))) {
    fail('describe_abi() differs from playground/mbel.abi.json');
  }

  const arithmetic = JSON.parse(exported.eval_expr('1 + 2', '{}', 'walk'));
  if (arithmetic !== 3) fail(`eval_expr smoke: expected 3, got ${arithmetic}`);

  const typeError = JSON.parse(exported.eval_checked('1 + "a"', '{}', 'walk'));
  if (!typeError || typeof typeError.$error !== 'string') {
    fail('eval_checked did not return the $error envelope for a type error');
  }
  if (typeError.$code !== 'CHECK_TYPE') {
    fail(`eval_checked did not classify the type error: ${JSON.stringify(typeError)}`);
  }
  if (!typeError.$pos || typeError.$pos.line !== 1) {
    fail(`eval_checked did not report $pos: ${JSON.stringify(typeError)}`);
  }

  const functionsJson = JSON.stringify({
    version: 1,
    functions: [{ name: 'inc', params: ['x'], body: 'x + 1' }],
  });
  const signatures = JSON.parse(exported.describe_functions(functionsJson));
  if (
    !Array.isArray(signatures) ||
    signatures[0]?.name !== 'inc' ||
    signatures[0]?.params?.[0] !== 'x'
  ) {
    fail(`describe_functions smoke: unexpected ${JSON.stringify(signatures)}`);
  }

  const badFunctions = JSON.stringify({
    version: 1,
    functions: [{ name: 'bad', params: ['x'], body: '1 + "a"' }],
  });
  const badRegistration = JSON.parse(
    exported.eval_with_functions('bad(1)', '{}', badFunctions, 'checked', 'walk'),
  );
  if (!badRegistration || typeof badRegistration.$error !== 'string') {
    fail('checked mode did not reject a body type error');
  }

  const arity = JSON.parse(
    exported.eval_with_functions('inc(1, 2)', '{}', functionsJson, 'checked', 'walk'),
  );
  if (!arity?.$error?.includes('invalid number of arguments')) {
    fail(`checked mode did not reject an arity mismatch: ${JSON.stringify(arity)}`);
  }

  // session lifecycle: create -> eval -> describe -> configure -> release
  const created = JSON.parse(
    exported.create_session(functionsJson, 'checked', 'walk', ''),
  );
  if (!created.handle) fail(`create_session smoke: ${JSON.stringify(created)}`);
  const sessionEval = JSON.parse(
    exported.eval_session(created.handle, 'inc(41)', '{}'),
  );
  if (sessionEval !== 42) {
    fail(`eval_session smoke: expected 42, got ${JSON.stringify(sessionEval)}`);
  }
  const describedSession = JSON.parse(exported.describe_session(created.handle));
  if (describedSession.handle !== created.handle) {
    fail(`describe_session smoke: ${JSON.stringify(describedSession)}`);
  }
  const lowered = JSON.parse(
    exported.configure_session(created.handle, '{"maxSteps":100}'),
  );
  if (lowered?.limits?.maxSteps !== 100) {
    fail(`configure_session smoke: ${JSON.stringify(lowered)}`);
  }
  const released = JSON.parse(exported.release_session(created.handle));
  if (released?.ok !== true) {
    fail(`release_session smoke: ${JSON.stringify(released)}`);
  }
  const gone = JSON.parse(exported.release_session(created.handle));
  if (gone?.$code !== 'HANDLE_UNKNOWN') {
    fail(`double release was not HANDLE_UNKNOWN: ${JSON.stringify(gone)}`);
  }
}

// ---------------------------------------------------------------------------
// wasm (MVP) C-ABI smoke calls
// ---------------------------------------------------------------------------

async function smokeCabi(manifest, module, path) {
  let instance;
  try {
    instance = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: { fd_write: () => 0 },
      __moonbit_time_unstable: { now: () => 0n },
    });
  } catch (error) {
    fail(`cannot instantiate ${path}: ${error.message}`);
  }
  const ex = instance.exports;
  const mem = ex.memory;
  const decoder = new TextDecoder('utf-16le');

  const readStr = (ptr) => {
    const n = new DataView(mem.buffer).getUint32(ptr - 4, true);
    return decoder.decode(new Uint8Array(mem.buffer, ptr, n * 2));
  };

  // The engine owns all of linear memory and bump-allocates upward, so it
  // may overwrite any host-written region between calls. Reserve scratch
  // once and re-write every input immediately before each call.
  const scratchBase = mem.buffer.byteLength;
  if (mem.grow(4) === -1) fail('cannot grow memory for C-ABI scratch');
  let cursor = scratchBase + 8;

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
    const ptrs = args.map(writeStr);
    return readStr(ex[name](...ptrs));
  }

  const described = JSON.parse(call('describe_abi', []));
  if (JSON.stringify(canon(described)) !== JSON.stringify(canon(manifest))) {
    fail('C-ABI describe_abi() differs from playground/mbel.abi.json');
  }

  const layout = JSON.parse(call('abi_layout', []));
  if (
    layout.stringEncoding !== 'utf16le' ||
    layout.lengthPrefix !== 'u32' ||
    layout.headerOffset !== -4
  ) {
    fail(`abi_layout reports an unexpected convention: ${JSON.stringify(layout)}`);
  }

  if (call('eval_expr', ['1 + 2', '{}', 'walk']) !== '3') {
    fail('C-ABI eval_expr smoke: expected "3"');
  }

  const typeError = JSON.parse(call('eval_checked', ['1 + "a"', '{}', 'walk']));
  if (typeError?.$code !== 'CHECK_TYPE' || !typeError?.$pos) {
    fail(`C-ABI eval_checked smoke: ${JSON.stringify(typeError)}`);
  }

  const functionsJson = JSON.stringify({
    version: 1,
    functions: [{ name: 'inc', params: ['x'], body: 'x + 1' }],
  });
  const created = JSON.parse(
    call('create_session', [functionsJson, 'checked', 'walk', '']),
  );
  if (!created.handle) fail(`C-ABI create_session smoke: ${JSON.stringify(created)}`);

  if (call('eval_session', [created.handle, 'inc(41)', '{}']) !== '42') {
    fail('C-ABI eval_session smoke: expected "42"');
  }

  const lowered = JSON.parse(
    call('configure_session', [created.handle, '{"maxSteps":100}']),
  );
  if (lowered?.limits?.maxSteps !== 100) {
    fail(`C-ABI configure_session smoke: ${JSON.stringify(lowered)}`);
  }

  if (JSON.parse(call('release_session', [created.handle]))?.ok !== true) {
    fail('C-ABI release_session smoke: expected {"ok":true}');
  }
  if (JSON.parse(call('release_session', [created.handle]))?.$code !== 'HANDLE_UNKNOWN') {
    fail('C-ABI double release was not HANDLE_UNKNOWN');
  }
}
