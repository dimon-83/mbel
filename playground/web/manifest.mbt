// SPDX-License-Identifier: Apache-2.0
// mbel playground — ABI introspection exports (proposal 0003, P0/P1).
//
// `describe_abi()` returns the canonical manifest, generated from
// playground/mbel.abi.json by tools/gen_abi_mbt.py. `abi_layout()` returns
// the string conventions of the C-ABI artifact (mbel-cabi.wasm) so a host
// can assert the layout it is about to rely on instead of trusting an
// undocumented runtime detail; playground/mbel-cabi.md is the prose
// version and tools/check_abi.mjs --cabi is the executable one.

///|
/// The machine-readable ABI manifest: abiVersion, engineVersion, the
/// artifact list with per-artifact host requirements, every export with
/// its parameter names, the error envelope shape, the stable error-code
/// vocabulary, the default budgets and the live-session cap.
pub fn describe_abi() -> String {
  abi_manifest()
}

///|
/// The C-ABI string layout, as a small JSON document. A `String` argument
/// and a `String` return are both a pointer to UTF-16LE code units with a
/// u32 character count immediately before the pointer and a 0x0000
/// terminator after the payload:
///
///   [ u32 char_count ][ utf16le code units ][ 0x0000 ]
///                      ^ pointer passed across the ABI
///
/// `headerOffset` is the count's offset from the pointer (negative:
/// before it), `terminator` is the terminator width in bytes.
/// `check_abi.mjs --cabi` fails when this drifts from what the artifact
/// actually does.
pub fn abi_layout() -> String {
  "{\"stringEncoding\":\"utf16le\",\"lengthPrefix\":\"u32\"," +
  "\"headerOffset\":-4,\"terminator\":2}"
}
