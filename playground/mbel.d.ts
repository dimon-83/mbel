// Type definitions for playground/mbel.wasm (wasm-gc, js-string builtins).
//
// Loading:
//
//   const { instance } = await WebAssembly.instantiateStreaming(
//     fetch("mbel.wasm"),
//     { __moonbit_time_unstable: { now: () => BigInt(Date.now()) } },
//     { builtins: ["js-string"], importedStringConstants: "_" },
//   );
//   const mbel = instance.exports as Mbel;
//
// The now import is `() -> i64` Unix **milliseconds**: JS must return a
// BigInt (a Number throws TypeError on the first now() call), and the
// engine converts ms to its internal nanosecond unit itself — passing
// nanoseconds here overflows int64.
//
// Requires Node >= 24 or a browser with the js-string builtins proposal
// (see the manifest's hostRequirements; verify with describe_abi()).
//
// Every function returns a JSON string (or a bare JSON value for pure
// expressions). Failures are the $error envelope:
//   {"$error": string, "$code": ErrorCode, "$pos"?: {line, col}}

export type MbelEngine = "walk" | "vm";

export type MbelMode = "eval" | "checked" | "legacy";

export type ErrorCode =
  | "ENV_JSON"
  | "FUNCS_JSON"
  | "FUNCS_VERSION"
  | "FUNCS_INVALID"
  | "MODE_UNKNOWN"
  | "ENGINE_UNKNOWN"
  | "HANDLE_UNKNOWN"
  | "HANDLE_LIMIT"
  | "LIMITS_INVALID"
  | "PARSE_SYNTAX"
  | "PARSE_EMPTY"
  | "PARSE_TOO_LARGE"
  | "PARSE_TOO_DEEP"
  | "CHECK_TYPE"
  | "CHECK_UNKNOWN_NAME"
  | "CHECK_UNKNOWN_FUNCTION"
  | "CHECK_ARITY"
  | "CHECK_FUNC_BODY"
  | "RUNTIME_TYPE"
  | "RUNTIME_UNKNOWN_CALL"
  | "RUNTIME_RECURSION"
  | "RUNTIME_BUDGET"
  | "INTERNAL";

export interface MbelError {
  $error: string;
  $code: ErrorCode;
  $pos?: { line: number; col: number };
}

export interface MbelLimits {
  maxNodes: number;
  maxDepth: number;
  maxSteps: number;
  userfnDepth: number;
}

export interface LimitsRequest {
  maxNodes?: number;
  maxDepth?: number;
  maxSteps?: number;
  allowRaise?: boolean;
}

export interface SessionInfo {
  handle: string;
  mode: MbelMode;
  engine: MbelEngine;
  functions: { name: string; params: string[] }[];
  limits: MbelLimits;
}

export interface AbiManifest {
  abiVersion: number;
  engineVersion: string;
  functionsFileVersion: number;
  artifacts: unknown[];
  exports: { name: string; kind: string; params?: string[]; returns?: string }[];
  errorEnvelope: { message: string; code: string; position: string };
  errorCodes: ErrorCode[];
  limits: MbelLimits;
  sessionLimit: number;
}

export interface Mbel {
  // Introspection
  describe_abi(): AbiManifest;
  abi_layout(): {
    stringEncoding: string;
    lengthPrefix: string;
    headerOffset: number;
    terminator: number;
  };

  // Stateless evaluation
  eval_expr(expr: string, env: string, engine: MbelEngine): unknown;
  eval_checked(expr: string, env: string, engine: MbelEngine): unknown;
  eval_jexl(expr: string, env: string, engine: MbelEngine): unknown;
  eval_with_limits(
    expr: string,
    env: string,
    engine: MbelEngine,
    limits_json: string,
  ): unknown;
  eval_with_functions(
    code: string,
    env: string,
    funcs_json: string,
    mode: MbelMode,
    engine: MbelEngine,
  ): unknown;
  describe_functions(funcs_json: string): unknown;

  // Session evaluation (register once, call many times)
  create_session(
    funcs_json: string,
    mode: MbelMode,
    engine: MbelEngine,
    defaults_json: string,
  ): SessionInfo | MbelError;
  eval_session(handle: string, expr: string, env: string): unknown;
  describe_session(handle: string): SessionInfo | MbelError;
  configure_session(handle: string, limits_json: string): unknown;
  release_session(handle: string): { ok: true } | MbelError;

  // Diagnostics
  dump_ast(source: string): unknown;
  disassemble(source: string, env: string): unknown;
}
