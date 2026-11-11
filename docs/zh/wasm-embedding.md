# 在宿主应用中嵌入 mbel

mbel 发布两个由同一份源码构建的 wasm 产物，并由同一份 manifest
（`playground/mbel.abi.json`，运行时也可通过 `describe_abi()` 导出获取）
描述。按宿主能力选择；两者的导出函数与 JSON 行为完全一致。

| | `playground/mbel.wasm` | `playground/mbel-cabi.wasm` |
| --- | --- | --- |
| 编译目标 | wasm-gc | wasm（MVP） |
| 调用约定 | js-string builtins | `mbel-cabi`（见 `playground/mbel-cabi.md`） |
| 字符串 | 原生 JS 字符串 | UTF-16LE 指针 |
| 宿主要求 | GC + js-string builtins 提案 | 仅需 WebAssembly MVP |
| 已验证宿主 | Node >= 24，Chrome/Edge 130+，Firefox 134+，Safari 18.4+ | 任意 MVP 宿主（已验证：Node、Python/wasmtime、Rust/wasmtime） |
| 校验命令 | `node tools/check_abi.mjs` | `node tools/check_abi.mjs --cabi` |

## 导出面（两个产物一致）

```
describe_abi()  abi_layout()
eval_expr(expr, env, engine)            eval_jexl / eval_checked / eval_with_limits
eval_with_functions(code, env, funcs, mode, engine)
create_session(funcs, mode, engine, defaults)  eval_session(handle, expr, env)
describe_session(handle)  configure_session(handle, limits)  release_session(handle)
describe_functions(funcs)  dump_ast(source)  disassemble(source, env)
```

全部返回 JSON（表达式求值成功时是裸 JSON 值，其余是对象）。所有失败
都走错误信封：

```json
{"$error":"message","$code":"CHECK_TYPE","$pos":{"line":1,"col":3}}
```

`$code` 取自 manifest 的 `errorCodes`；解析错误与 checked 模式错误携带
`$pos`。宿主应基于 `$code` 分支处理，不要依赖错误消息文本。

## 加载 `mbel.wasm`（JS 宿主）

```js
const { instance } = await WebAssembly.instantiateStreaming(
  fetch("mbel.wasm"),
  { __moonbit_time_unstable: { now: () => BigInt(Date.now()) } },
  { builtins: ["js-string"], importedStringConstants: "_" },
);
const out = JSON.parse(instance.exports.eval_expr("1 + 2", "{}", "walk"));
```

`now` 导入的 ABI 是 `() -> i64` Unix **毫秒**:JS 侧必须返回 BigInt
(Number 会在首次调用 `now()` 时抛 TypeError),引擎内部再换算成纳秒
——传纳秒会被重复换算,int64 溢出。

完整导出面见 `playground/mbel.d.ts`。对你实际发布的产物执行
`node tools/check_abi.mjs`：它会核对导出集合、交叉校验 `engineVersion`
与 `moon.mod`、深比较 `describe_abi()` 与 manifest 文件，并对每种签名
形状（含 session 生命周期）做冒烟调用。

## 加载 `mbel-cabi.wasm`（任意宿主）

完整布局契约见 `playground/mbel-cabi.md`。要点：

- **导入。** `wasi_snapshot_preview1.fd_write`(桩即可)与
  `__moonbit_time_unstable.now`(`() -> i64`,Unix 毫秒,常量即可;
  JS 宿主注意 i64 对应 BigInt,例如 `() => 0n`)。
  `_start` 位于 start section，实例化时自动执行。
- **字符串。** 每个 `String` 参数/返回值都是单个 `i32` 指针：
  `ptr - 4` 处是 `u32` 字符数，`ptr` 起是 UTF-16LE 数据，数据后跟两个
  NUL 码元。`abi_layout()` 会返回这份约定。
- **线性内存。** 引擎拥有整段线性内存并以向上的 bump 指针分配。为
  scratch 调用 `memory.grow`，在其中构造输入串，且**每次调用前都重写
  一遍**；调用返回后立即把结果拷出。绝不要写进你没有 grow 出来的内存。
- **错误、预算、session** 与 js-string 产物完全一致；`configure_session`
  与 `eval_with_limits` 接受 `maxNodes` / `maxDepth` / `maxSteps` /
  `allowRaise`，且只允许下调。

三个宿主的可运行示例在 `tools/bindings/`（Node、Python + wasmtime、
Rust + wasmtime）。

## 版本与兼容性策略

- `abiVersion`（当前 `1`）只在**调用约定**或错误信封发生变化时递增，
  属破坏性事件。宿主应记录 `describe_abi()` 返回的值，遇到不同的主版本
  拒绝运行。
- `engineVersion` 跟随 crate 版本（SemVer）。同一主版本内，修复与新特性
  可以扩展导出面或新增 `errorCodes`；既有导出保持签名与语义不变。
- manifest 随时可能新增键；未知键是增量式的。`sessionLimit` 与
  `limits` 描述的是你当前加载产物的编译默认值，不是跨版本承诺。
- 函数文件格式有自己的 `functionsFileVersion`；session 或函数文件加载
  失败会返回 `FUNCS_VERSION`，不会被静默地按旧格式解读。
- 在 CI 中用 `tools/check_abi.mjs [--cabi]` 校验发布的产物——wasm 与
  manifest 一旦漂移，它就会报错而不是放行。

## 安全说明

- 求值全程有预算（`maxNodes` / `maxDepth` / `maxSteps`，默认值见
  manifest）；预算耗尽返回 `RUNTIME_BUDGET`，不会 trap。
- 面向不可信输入的宿主应使用 `eval_with_limits`（或 session +
  `configure_session`）把预算降到默认值以下；上调必须显式传
  `allowRaise: true`。注意"只许下调"的比较基准是编译**默认值**，不是
  session 的当前值——若不可信输入能触达 `configure_session`，宿主侧需
  自行保证单调收紧。
- session 数量有上限（`sessionLimit`，默认 16）。用完请释放句柄；
  泄漏的句柄会让下一次创建返回 `HANDLE_LIMIT`。
