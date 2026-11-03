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
// Usage: node tools/check_abi.mjs [wasm] [manifest]

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const wasmPath = process.argv[2]
  ? resolve(process.argv[2])
  : resolve(root, 'playground/mbel.wasm');
const manifestPath = process.argv[3]
  ? resolve(process.argv[3])
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
  module = await WebAssembly.compile(bytes, {
    builtins: ['js-string'],
    importedStringConstants: '_',
  });
} catch (error) {
  fail(`cannot compile ${wasmPath}: ${error.message}`);
}

const actual = WebAssembly.Module.exports(module)
  .map((entry) => `${entry.name}:${entry.kind}`)
  .sort();
const expected = manifest.exports
  .map((entry) => `${entry.name}:${entry.kind}`)
  .sort();
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  fail(
    `wasm exports differ from manifest\n  wasm:     ${actual.join(', ')}\n  manifest: ${expected.join(', ')}`,
  );
}

const instance = await WebAssembly.instantiate(module, {
  __moonbit_time_unstable: { now: () => 0 },
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

console.log(
  `ABI OK: ${wasmPath} matches ${manifestPath} (${manifest.exports.length} exports, engine ${manifest.engineVersion})`,
);
