# expr 差距分析 — 阶段 4 追平技术评估

状态:2026-09-04。证据来源:/Users/dexter/workspace/expr(expr-lang/expr,commit 4b31df3,v1.17.8+8),所有条目均经源码核实;mbel 现状为本仓库实现(Jexl 方言 + JS 动态语义,104 parity 测试 + ~3400 表达式差分对拍)。

## 1. 差距清单

### A. 语法层(expr 有,mbel 无 — lexer/parser 需扩展或重写)

| expr 特性(证据) | mbel 现状 | 改动 | 估(人日) |
|---|---|---|---|
| `if cond { } else { }` 块式条件(parser.go:338-364,可嵌套 else-if) | 仅三元 `?:` | parser 重写 | 4.4.2 内 |
| `let x = 42;` 声明 + `;` 序列表达式(parser.go:323-336) | 无 | parser 重写 | 同上 |
| 可选链 `?.` / `?.[`(ChainNode) | 无 | parser 重写 | 同上 |
| `??` 空合并(与其它二元混用报错,parser.go:271-273) | 无 | parser 重写 | 同上 |
| 切片 `a[1:3]`/`a[:]`/负边界(parser.go:839-899);范围 `1..9`(优先级 25,生成数组) | 无 | parser 重写 | 同上 |
| 谓词 lambda:`filter(xs, {# % 2 == 0})`,`#`/`#acc`/`#index`/省略 `#` 相对访问(parser.go:419-435) | 过滤器 `[.x==1]`(Jexl 语义,非函数式) | parser 重写 | 同上 |
| 管道接函数 `x\|f()\|g()`(优先级 0) | 管道接 transform(语义不同) | parser+eval | 同上 |
| `not in/matches/contains/startsWith/endsWith` 后缀否定;链式比较 `a<b<c`(parser.go:907-940) | 无 | parser 重写 | 同上 |
| `matches` 正则(右端字面量编译期编译,checker.go:461-467) | 无 | 依赖 4.5 | 计入 4.5 |
| `**`/`^` 幂,右结合,优先级 100;一元 `-` 90(`-2^2` = `-(2^2)`) | `^` 左结合优先级 50 | parser 扩展 | 同上 |
| 数字字面量:hex/oct/bin/`_` 分隔/指数/`.5`(parser.go:485-524) | 仅十进制 | lexer 扩展 | 4.4.1 3-4d |
| 字符串:`\u{...}`/`\xNN`/八进制转义;原始反引号串;字节串 `b".."`(lexer utils.go:110-337) | 单双引号 + `\"`/`\\` | lexer 扩展 | 同上 |
| 注释 `//` 与 `/* */`(state.go:190-224) | 无 | lexer 扩展 | 同上 |
| `$env`、方法调用 `foo.bar()`、`::` 命名空间 | 无 | parser 重写 | 同上 |
| 关键字式运算符词法(in/or/and/not/matches/contains/…) | `in` 特判 | lexer 扩展 | 同上 |

### B. 语义/类型层(mbel 为 JS 动态语义;expr 为严格静态)

| expr | mbel | 改动 | 估(人日) |
|---|---|---|---|
| int/float 双通道:`/` 恒 float、`%`/`..` 仅整数、窄→宽提升、整→浮替换(checker.go:1184-1220) | 全 Double + JS 弱类型 | 值模型(4.4.3) | 5-8 |
| checker 类型推断(checker.go 1353 + nature/ 812):运算符规则、内置泛型特判(builtinNode 704-957)、env 白名单、类型化 AST(Nature 标注) | 无静态检查;错误无源码位置 | 新增(最大单项) | 12-18 |
| 编译错误 `行:列 \| expr \| ....^` 定位(file/error.go) | 错误仅消息 | 新增(lexer 位置) | 1-2(计入 4.4.1) |
| nil 语义、严格 `==` | loose `==`、undefined 传播、ToPrimitive 全套(需保留给 Jexl legacy) | 语义切换 4.4.5 | 4-6 |

### C. 工程层(安全/性能 — 方言无关,现有引擎先行)

| expr | mbel | 改动 | 估(人日) |
|---|---|---|---|
| parser 节点上限 DefaultMaxNodes=1e4(parser.go:100-114) | 无限制 | parser 计数 | 4.1:1 |
| VM 内存预算 DefaultMemoryBudget=1e6(vm.go:690-695)+ Safe 函数记账(builtin.go) | 无 | evaluator 预算 | 4.1:1-2 |
| 嵌套集合深度 MaxDepth=1e4 + ErrorMaxDepth(builtin.go:21-23) | 无 | evaluator 深度 | 4.1:1 |
| env 白名单(未知名报错;Strict/AllowUndefinedVariables) | 上下文任意 key 缺失返回 undefined(Jexl 语义) | 语言层后 | 计入 4.4.4 |
| optimizer 12 pass(optimizer/ ≈1133 行):fold/inArray/inRange/filterMap/filterLen/filterFirst/filterLast/谓词合并/sumRange/sumArray/sumMap/countAny/countThreshold/constExpr | 无 | 新增 | 4.3:6-8 |
| 字节码 VM(compiler.go 1357 + vm/ 1212,89 opcode,类型化作用域、常量池、特化比较/调用) | tree-walk | 新增后端 | 4.3:10-14 |

### D. 内置库(builtin/builtin.go,64 个条目)

| 类 | 函数 | 依赖 | 估(人日) |
|---|---|---|---|
| 谓词聚合 15 | all none any one filter map count sum find findIndex findLast findLastIndex groupBy sortBy reduce | 谓词 lambda 语法(4.4.2 后) | 语言层后 4-6 |
| 数学 8 | abs ceil floor round max min mean median | 无 | 1-2 |
| 字符串 16 | trim trimPrefix trimSuffix upper lower split splitAfter replace repeat join indexOf lastIndexOf hasPrefix hasSuffix string | 无 | 3-4 |
| 转换 9 | int float string type toJSON fromJSON toBase64 fromBase64 toPairs fromPairs | JSON 用 core json | 2-3 |
| 时间 4 | now duration date timezone(含 Go time 方法直调) | MoonBit 无 time — 4.5 | 4-6 |
| 集合 9 | len first last get take keys values reverse uniq concat flatten sort | 无 | 2-3 |
| 位运算 8 | bitand bitor bitxor bitnand bitnot bitshl bitshr bitushr | Int64 值模型(4.4.3) | 1-2 |
| matches/正则 | — | MoonBit 无 regexp — 4.5 | 4-6 |

### E. 架构差异(不可 1:1,需显式裁剪并记录)

1. **反射**:expr 经 Go reflect 访问任意 struct env 的字段/方法(运行时 Field/Method 索引、methodset 缓存)。MoonBit 无反射 → env 收敛为引擎数据模型(Value ObjectVal/ArrayVal);"任意宿主结构体作为 env"裁剪。影响公开 API 形态与 `foo.bar()` 方法调用的宿主扩展方式(改为注册式)。
2. **time/regexp**:expr 直接依赖 Go time 与 regexp(方法集很大:`.Year() .In(tz) .Seconds()` 等)。MoonBit 核心无 → 4.5 最小自实现或 FFI(wasm/js 后端可注入宿主实现)。最大外部依赖风险。
3. **生成代码**:VM runtime helpers 3718 行 + func_types 370 行为 Go 生成代码;MoonBit 侧以手写特化/泛型替代,不追求同构。
4. **性能口径**:wasm-gc 与 Go 原生无可比性;验收 = 自身基准 + 复杂度同阶(4.3 内建 bench)。
5. **错误通道**:expr panic→recover→file.Error;MoonBit checked errors(raise)天然等价,不需 recover。

## 2. 分期路线与工作量(单人日)

| 期 | 内容 | 估 | 依赖 | 验收 |
|---|---|---|---|---|
| 4.1 | 安全预算:节点上限/求值深度/步数,可配置 | 2-3 | 无 | 预算测试 + 104 回归 + corpus 复验 |
| 4.2 | 内置库纯计算(Jexl 函数池先交付,非谓词) | 10-14 | 无 | expr fixture 转写 |
| 4.3 | 字节码 VM + optimizer(核心 pass) | 15-20 | 无 | 自基准 + 语义等价测试 |
| 4.4.1 | lexer 扩展(字面量家族/注释/位置/关键字) | 3-4 | — | lexer fixture 转写 |
| 4.4.2 | parser 重写(Pratt,新 AST,谓词作用域) | 10-14 | 4.4.1 | parser fixture 转写 |
| 4.4.3 | 值模型 Int64/Float 分离 + Nature 标注 | 5-8 | 4.4.2 | checker 前置 |
| 4.4.4 | checker 类型检查 | 12-18 | 4.4.3 | checker fixture |
| 4.4.5 | 严格语义引擎(mbel::expr)+ Jexl legacy 并存 | 4-6 | 4.4.4 | expr want 表 167 行 |
| 4.5 | time/regexp 依赖(最小实现或 FFI) | 5-10 | 可并行 | expr time/regexp fixture |
| 4.6 | 验证贯穿:fixtures 转写 + (go 可用则)差分 | 8-12 | 各期 | 转写覆盖率 |

**合计 ≈ 75-105 人日(3.5-5 人月)**,低-中置信。单项最大:checker(12-18d)、parser 重写(10-14d)、VM+optimizer(15-20d)。

## 3. 建议执行顺序与 gate

4.1 → 4.2 → 4.3(工程层,方言无关,立即改善 Jexl 安全/性能短板,现有 104 测试与差分资产不破坏);随后 **4.4 gate 评审**(对照本清单重新确认语言层是否启动、是否裁剪),4.4.x 顺序执行;4.5 并行;4.6 贯穿。

## 4. Stage 4.2/4.3 delivery status (2026-09-05)

Delivered (127/127 tests green; all Jexl differential corpora remain
byte-identical):

- **4.2 builtins** (`builtin/` package, seeded into every Jexl instance):
  math 8 (abs/ceil/floor/round/max/min/mean/median, Go round semantics),
  strings 16 (trim*/upper/lower/split/splitAfter/replace/repeat/join/
  indexOf/lastIndexOf/hasPrefix/hasSuffix/string), collections 12 (len/
  first/last/get/take/keys/values/reverse/uniq/concat/flatten/sort),
  conversions 9 (int/float/string/type/toJSON/fromJSON/toBase64/
  fromBase64/toPairs/fromPairs, with own UTF-8 + base64 codec),
  bitwise 8 (Int64 semantics via the Double value model), time
  minimal set (now/duration/date ISO/timezone=UTC only).
- **4.2b expr operators**: `??` (nil coalescing, on-demand), `..`
  (range, memory-budgeted at 1e6 elements), `matches` (limited regex —
  the MoonBit core regex engine behaves as literal matching; full
  RE2-style patterns remain future work).
- **4.3 partial**: constant-folding optimizer pass (`constant_fold`,
  expr-style `fold`) wired into Expression compile; bytecode VM not
  started.

New divergences recorded:
| Case | expr | mbel | Cause |
|---|---|---|---|
| `type(1)` | "int" | "number" | no int/float split until 4.4.3 |
| `?? mixed with other ops` | parse error | accepted | parser-level check not ported |
| invalid regex pattern | compile error | no match | MoonBit core regex is literal-only |
| `1..2` (Jexl corpus) | n/a | range | mbel superset; moved to tools/divergence.txt |
| time objects / timezones | Go time.Time | unix-ms numbers | stage 4.5 cut item |

## 5. 已决策与待决策

- 已决策:目标 = "expr 语言定义 + 官方测试"为验收基线(而非 Go API 面);E 类裁剪项显式记录。
- 待 4.4 gate:Jexl legacy 保留期、$env/方法调用宿主扩展方式、time/regexp 实现路线(FFI vs 自实现)。

## 6. 2026-09-07 增补:playground 验收用例驱动的对齐修复

expr playground 验收用例(4 条)暴露三类问题,处置如下(证据:v1.17.8 parser.go / 官方语言定义):

1. **方括号谓词 `items[.price <= 2].name` —— Jexl 兼容扩展(显式偏离,记录在案)**
   expr-lang 的 `[` 后只接受索引/切片,裸 `.` 在 depth 0 直接 parse error
   (谓词上下文仅由 parseCall 对 `predicates` map 函数的实参开启);
   官方语言定义中 `[]` 仅用于元素访问/切片。mbel expr 前端现为对齐实现,
   但作为 Jexl 源码兼容扩展,**expr 前端额外接受 `[.expr]` 相对过滤**:
   lower 到 legacy `FilterExpression(relative=true)`,Walk/Vm 走既有
   eval_filter/compile_filter 语义,结果与 Jexl 方言一致。此为"mbel 比
   expr-lang 多接受"的显式偏离,依据 AGENTS.md 在此记录。

2. **管道接谓词聚合 `tweets | filter(.Content contains "Hello") | map(.User) | first()` —— 对齐修复**
   expr 的管道经 `parseCall(ident, [left], true)` 脱糖,谓词位的实参照常
   进入谓词上下文(`parsePredicate`/depth++)。mbel 原实现不对管道右侧
   实参开放谓词上下文 → 裸 `.field` parse error。已修:管道右侧聚合调用
   的第 0 个显式实参按谓词上下文解析(`parse_call_args_for(piped=true)`),
   `first()` 零参管道调用不受影响。

3. **指针与裸管道严格化(对齐修复)**
   - expr 仅在谓词上下文(depth > 0)接受 `#`/`#index`/`#acc`;mbel 原先
     任意位置放行(运行时求值为 nil)。已在 parsePrimary 按 `in_predicate`
     门控,非谓词位置报 parse error。
   - expr 管道右侧必须是带括号调用(`| fn`、`| x.m()` 均 parse error);
     mbel 原先接受裸 `| fn`。已收紧;language-definition 管道行同步修正。

4. **时间运算(case 1/4)→ 计入 4.5(记录在案,暂不实现)**
   用例:`request.Time - resource.Age < duration("24h")`,env:
   request.Time = "2024-01-01T23:59:00Z"、resource.Age =
   "2024-01-01T00:00:00Z",expr-lang 预期 `true`(时间串按 RFC3339 解析,
   23h59m = 86340000000000ns < 86400000000000ns)。
   现状盘点(2026-09-07):`duration()`/`date()`/`now()`/`timezone()` 内置
   已有最小 UTC/ISO 实现(builtin/time.mbt,duration 返回纳秒数);缺的是
   **时间串在运算符里的隐式解析** —— `request.Time - resource.Age` 当前按
   JS 弱类型得 NaN(string - string),进而整条表达式得 `false`(非报错)。
   4.5 需落时:RFC3339 串在 `-`/比较等二元运算中隐式转为时间值
   (time - time → Duration 纳秒),补 Duration 值模型与比较;依赖
   §D"时间 4"行与 §E.2(FFI vs 自实现)。**4.5 落实时间运算时,该用例
   必须进入 expr eval/parity 测试(预期 true)。**
