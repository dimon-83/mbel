# expr 语言定义覆盖对照(mbel vs expr-lang)

对照基准:https://expr-lang.org/docs/language-definition 与
expr 仓库 docs/language-definition.md(commit 4b31df3, v1.17.8)。
测试证据:mbel 189 个 test 函数(`moon test` 常规计数 168 + 21 个
bench 经 `moon bench` 运行)——lexer_test 21 / parser_test 29 /
evaluator_test 28 / expr_test 19(parser 9 · eval 9 · opcode 1)/
engine_test 92(API 26 · 预算 7 · builtin 16 · 聚合 10 · Walk-vs-Vm
对拍 9 · 稳定性 3(7 场景套件×双引擎+引擎间一致性)· bench 21);
三目标(native / wasm-gc / js)均 168/168;另与真实 Jexl 的差分
corpus(3360+ 表达式,byte-identical)。双引擎性能/稳定性实测见 §7。

图例:✅ 已实现且有测试 | 🟡 部分/语义受限 | ❌ 未实现

## 1. 字面量与数据结构

| 特性 | 状态 | 测试证据 | 备注 |
|---|---|---|---|
| 整数(十进制) | ✅ | lexer_test (21), corpus | JS double 承载,±2^53 内精确 |
| 浮点 | ✅ | corpus `0.1+0.2` 等 | 正确舍入解析;最短格式输出 |
| hex/oct/bin/`_` 分隔 | ❌ | — | 4.4.1 lexer |
| 指数字面量 `1e9` | ❌ | — | 4.4.1 lexer |
| `.5` 形式 | ❌(Jexl 把 `.` 当元素) | corpus `1..2` 类 | 4.4.1 |
| 字符串 '…' / "…" | ✅ | lexer_test, corpus | 转义 `\"` `\\` |
| 转义 `\xNN \uXXXX \u{…}` 八进制 | ❌ | — | 4.4.1 |
| 原始字符串 `` `…` `` | ❌ | — | 4.4.1 |
| 字节串 b"…" | ❌ | — | 4.4.1 + 值模型 Bytes |
| 布尔 true/false | ✅ | lexer_test | |
| nil | 🟡 | ctx corpus `foo == null` | 无 nil 字面量(Jexl 无);NullVal 运行时存在 |
| 数组 [1,2,3] | ✅ | parser_test, corpus | |
| map {a:1, 'b':2} | ✅ | parser_test, corpus | key: ident/string/number |
| 注释 // /* */ | ❌ | — | 4.4.1 |

## 2. 运算符

| 特性 | 状态 | 测试证据 | 备注 |
|---|---|---|---|
| 算术 + - * / | ✅ | evaluator_test, corpus | JS 语义(`/` 不恒 float) |
| 整除 // | ✅ | corpus `7//2`=3 | Math.floor |
| 取模 % | ✅ | corpus | 精确 fmod(Dekker) |
| 幂 ^ | 🟡 | corpus | Jexl:左结合优先级 50;expr:`^`/`**` 右结合 100 → 4.4.2 |
| ** 幂 | ❌ | — | 4.4.2 |
| 比较 == != < <= > >= | ✅ | evaluator_test, corpus | JS loose ==;expr 严格 → 4.4.5 |
| 逻辑 && \|\| ! | ✅ | evaluator_test(短路) | 惰性求值 |
| not / and / or 词形 | ❌ | — | 4.4.1 关键字词法 |
| in / not in | ✅ / ❌ | corpus | not 后缀否定 → 4.4.2 |
| ?? 空合并 | ✅ | builtin_test | 混用限制未移植(接受 1+2??3) |
| .. 范围 | ✅ | builtin_test | 1e6 内存预算 |
| 切片 [1:3] [:3] [3:] | ❌ | — | 4.4.2(filter 子解析扩展) |
| 可选链 ?. /?.[ | ❌ | — | 4.4.2 |
| 链式比较 a<b<c | ❌ | — | 4.4.2 |
| matches 正则 | 🟡 | builtin_test | MoonBit core regex=字面量;完整 RE2 → 4.5 |
| contains/startsWith/endsWith 运算符 | ❌(有同名函数) | builtin_test | 4.4.2 |
| 管道 \| | 🟡 | jexl_test, corpus | Jexl transform 管道;expr 函数管道 → 4.4.2 |
| 一元 -/!(优先级) | 🟡 | corpus `-2^2` | expr -90 < ^100;Jexl 词法负号 |

## 3. 表达式形式

| 特性 | 状态 | 备注 |
|---|---|---|
| 三元 ?: / Elvis ?: | ✅ | evaluator_test, corpus |
| if/else 块 | ❌ | 4.4.2 |
| let 声明 + ; 序列 | ❌ | 4.4.2 |
| 谓词 {#…} + #/#acc/#index/省略 # | 🟡 | 省略花括号形式 `filter(xs, # > 2)` 与 `.field` 相对访问已实现(expr 兼容);`{...}` 花括号包裹形式待 parser 重写 |
| 方法调用 foo.bar() | ❌ | 4.4.2(注册式宿主函数) |
| $env | ❌ | 4.4.4 |
| 成员/索引/动态键 | ✅ | parser_test, corpus |
| 相对过滤器 [.x==1] | ✅ | Jexl 形式(expr 无此语法) |

## 4. 内置函数(64 个)

| 类 | 状态 | 详情 |
|---|---|---|
| 数学 8 | ✅ 8/8 | builtin_test;round=Go 半远离零 |
| 字符串 16 | ✅ 16/16 | upper/lower 仅 ASCII(差异记录) |
| 集合 12 | ✅ 12/12 | get 越界 nil;sort 数字/字符串 |
| 转换 9 | 🟡 9/9 实现 | type() 返回 "number"(无 int/float);toJSON NaN→null(expr 报错) |
| 位运算 8 | ✅ 8/8 | Int64 语义 |
| 时间 4 | 🟡 最小集 | now/duration/date(ISO)/timezone=UTC;无 time.Time 对象/方法/多 layout/时区库 |
| 谓词聚合 15 | 🟡 15/15 函数式 | 函数式调用形式已交付(2026-09-06,如 `count(list, # > 2)`):# /#index/#acc 指针、省略 # 的相对访问、子 Program+类型化槽位;`{expr}` 花括号谓词与 `list[?pred]` 语法待 Parser 重写(§6.2) |

## 5. 工程能力

| 特性 | 状态 | 备注 |
|---|---|---|
| 节点上限(1e4,可配) | ✅ | budget_test |
| 嵌套上限(1000;expr 无此项,wasm 栈必需) | ✅ | budget_test |
| 求值深度 + 步数预算(跨 filter 共享) | ✅ | budget_test, stability_test |
| env 白名单 / Strict | ❌ | 4.4.4(Jexl 缺失键→undefined) |
| 常量折叠 | ✅ | builtin_test fold 套件 |
| 12-pass optimizer 其余 | ❌ | 4.3 剩余(需 VM 落点) |
| 字节码 VM | ✅ v2(指令化) | 21 opcode(0-20)平行 Int 数组 + 编译期预解析 + 栈预分配 + 原生过滤器/聚合循环帧(消除每元素 Evaluator 分配);`Engine::set_engine(Walk \| Vm)`,默认 Walk;207 corpus + 手写用例 Walk vs Vm **真绿**(值+错误消息严格相等,NaN-aware;f37f10d 恢复端到端分发后首次为真,此前"假绿"见 §7 勘误);实测:迭代型负载 Vm 领先(过滤器 native −69% / wasm −39%,聚合 native −30~41%),微负载 Vm 落后(常量求值 +38~118%)——同批数据见 §7 |
| 编译错误 行:列\|…^ | ❌ | 4.4.1 位置信息 |
| 差分验证 harness | ✅ | tools/(expr 侧待 go 差分) |
| 并发模型 | ✅ 文档化 | wasm 单线程原子 eval;实例隔离测试 7 项 |

## 6. 剩余功能实现方案(阶段 4.3 剩余 + 4.4/4.5)

### 6.1 字节码 VM(4.3)——v1 + v2 已交付
**双引擎架构(2026-09-05/06,0010ef3/fce4d69)**:`evaluator/vm.mbt`。
21 opcode(0-20:CONST/LOADCTX/LOADREL/FETCH/CALLBINFN/CALLUNFN/
MATCHES/ANDJUMP/ORJUMP/COALESCE/JUMP/JUMPIFFALSE/ARRAY/OBJECT/
CALLFUNC/FILTERBEGIN/FILTEREND/FILTERSTATIC/LAZYBIN/LOADSLOT/
CALLAGG)编码为平行 Int 数组(opcode+operand),常量池去重
(CVal/CAst/CKeys/CFn/CUFn/CAgg;2026-09-06 增 CRaise 承载"抵达即
raise"的缺省分支);编译期运算符预解析为直接函数引用(运行时零
查找)、栈预分配+sp 指针(编译期 max_stack 模拟)、patch 式跳转;
语义函数单源(apply_binary_op/call_pool_function/fetch_from/
aggregate_call 由两引擎共享,指令只做调度);相对过滤器/静态索引
指令化(FILTERBEGIN/END、FILTERSTATIC),谓词聚合编译为 CALLAGG
子 Program + 单子 VM 跨元素复用(LOADSLOT 类型化槽位 #/#index/#acc);
手动求值运算符(LAZYBIN)按需回调 tree-walk(共享预算);CLI
`argv[3]=vm` 可选。
剩余:let 变量槽、切片/可选链指令(依赖 4.4.2)、Disassemble 输出。

**端到端分发补遗(f37f10d,2026-09-06)**:`Expression::eval` 自 4.3
引入 VM 起(0010ef3)到 f37f10d 前一直没有分发到 Vm——所有经
`Engine::eval`/`Expression::eval` 的"Vm"场景实际都在跑 Walk:
vm_parity"全绿"是假绿,fa21fe9 性能报告与 README 性能表的 Vm 列
(全部 ≈Walk±4%)因此失效。f37f10d 恢复分发,并修复该分发暴露的
调度缺陷:LOADSLOT 缺执行分支(谓词聚合报 unknown opcode)、
`&&`/`||`/`??` 急切编译两侧(短路失效)、elvis `?:` 真值分支结果
丢失、`?:`/`a ?:` 缺省分支静默 Undef 而非报错、FILTERBEGIN/END 的
pc 语义(相对括号过滤器栈下溢)。修复后 207 条 corpus + 全节点
手写用例的 Walk vs Vm 对拍**首次真正执行**且全绿(值+错误消息
严格相等,NaN-aware);性能与稳定性实测见 §7。

### 6.2 语言层(4.4,~35-50d,gate 后启动)
1. **4.4.1 lexer(3-4d)**:数字家族(hex/oct/bin/_/exp/`x.y`)、字符串家族
   (原始/字节/\u{}/八进制)、注释、关键字词法(in/and/or/not/matches/contains/
   startsWith/endsWith/let/if/else)、Token 增加 offset/line/col(file.Source)。
   评审补充:`.5` 仅在数字起始上下文词法化为浮点(与成员 `.` 由 parser 状态
   区分);`and/or/not/matches` 等采用上下文相关关键字策略(词法统一出
   Ident,parser 按位置判定运算符/标识符,保障 `a and b` 与变量名 `and`
   共存);八进制转义降级范围与错误文案文档化。
2. **4.4.2 parser 重写(10-14d)**:Pratt/递归下降替换状态机(状态机无法自然表达
   块/序列/谓词)。AST 新节点:MemberNode(method?)/ChainNode/OptionalChain/
   SliceNode/RangeNode/PredicateNode/PointerNode(#/#acc/#index)/IfNode/
   VariableDeclaratorNode/SequenceNode/IntegerNode/FloatNode。要点:比较链合取、
   ?? 混用报错、not 后缀否定表、`-2^2`=-(2^2)(一元 90 < 幂 100)、谓词作用域
   深度计数(与 Jexl corpus 的回归通过 jexl-legacy 包双轨保证)。
3. **4.4.3 值模型类型化(8-12d,评审上调)**:类型**定义与 Parser 并行先行**
   (IntVal(Int64)/FloatVal 分离、全部运算符与内置函数签名修订清单),
   实现在 Parser 完成 ~70% 时启动并逐步替换 NumVal;涉及算术/比较/位运算/
   转换全部行为调整。Int64 溢出行为文档化(Go 语义:回绕)。评审意见:
   "保留统一 NumVal"的降级方案不作为首选(后拆成本更高)。Jexl legacy
   引擎继续用现 Value。
4. **4.4.4 checker(12-18d,拆两阶段降险)**:
   第一阶段(4-6d):env 白名单(严格/宽松)、错误 `行:列 | expr | ....^`、
   基本运算符类型检查(如 string+int 报错)——尽早交付可用错误反馈;
   第二阶段(8-12d):完整 Nature 推断(运算符规则表、数组/Map 元素类型、
   内置泛型特判)、AsBool/AsInt 期望检查。
5. **4.4.5 语义切换(4-6d)**:新顶层 `mbel::expr` API(Compile/Run/Eval + Options
   对齐:expr.Env→数据 Value、Optimize、MaxNodes、AsBool…);Jexl+JS 语义层降级
   为 legacy 包(104 测试锁定)。
6. **谓词聚合 15(4-6d,依赖 4.4.2)**:filter/map/all/… 以 PredicateNode 特化
   (tree-walk 先行,VM 循环指令随后);groupBy/sortBy/reduce 同批。
7. **4.5 依赖(P2/P3,评审修订)**:正则——"RE2 全特性"措辞修正(RE2 本身
   不支持反向引用;应为"正则全特性"裁剪):范围缩至**字面量/字符类/量词/
   锚点/非捕获分组**,明确不支持捕获替换、反向引用、Unicode 属性、环视;
   自实现估计上调至 2000+ 行(含解析/编译/NFA 执行,16-20d);FFI 注入宿主
   RegExp(js/wasm)为快速路径但牺牲可移植性,API 边界显式化。时间——civil
   日历(已有 days_from_civil 基础)+ 固定偏移;完整 tzdata 预留外部文件
   加载接口,可永不内置。两项均延后至核心稳定。

### 6.3 覆盖率目标
4.4 完成后:expr 官方 TestExpr 167 行 want 表全量转写 + parser/checker/optimizer
表抽样 ≥60%;4.5 后 builtin_test 904 行对齐。

## 7. 双引擎实测:性能与稳定性对比(2026-09-06,f37f10d 后)

同批采集,`moon bench -p engine_test`(wasm-gc)/`--target js`/
`--target native`,每项 10×N runs,mean(σ 0.5-5%,见日志)。
**本表为 Vm 首次真正端到端执行的数据**(勘误见 §6.1):此前
fa21fe9/README 报告的两引擎"±4% 持平"是分发缺失的产物(两列实为
Walk),已失效。Δ 为 Vm 相对 Walk(Vm 慢为 +)。

| 场景(除注明均为预编译后求值) | 口径 | Walk | Vm | Δ |
|---|---|---|---|---|
| 端到端编译+求值(parse+fold[+codegen]) | native | 13.8 µs | 14.4 µs | +4.7% |
| | js (V8) | 5.45 µs | 7.05 µs | +29% |
| | wasm-gc | 6.33 µs | 6.37 µs | ≈0 |
| 短谓词过滤器 `items[.qty>2].price`(100 项) | native | 5.50 µs | 3.10 µs | **−44%** |
| | js | 4.68 µs | 4.64 µs | ≈0 |
| | wasm-gc | 4.48 µs | 3.72 µs | −17% |
| 长谓词过滤器(~12 指令/元素,100 项) | native | 24.6 µs | 7.60 µs | **−69%** |
| | js | 17.7 µs | 13.5 µs | −23% |
| | wasm-gc | 16.3 µs | 10.0 µs | −39% |
| 聚合 map(100 项) | native | 4.31 µs | 3.03 µs | **−30%** |
| | js | 4.42 µs | 4.50 µs | +2% |
| | wasm-gc | 3.57 µs | 3.33 µs | −7% |
| 聚合 filter+sum(100 项) | native | 7.02 µs | 4.17 µs | **−41%** |
| | js | 6.20 µs | 6.36 µs | +3% |
| | wasm-gc | 6.09 µs | 4.76 µs | −22% |
| 50 项链式(不可折叠) | native | 1.35 µs | 615 ns | **−55%** |
| | js | 1.33 µs | 1.02 µs | −23% |
| | wasm-gc | 1.60 µs | 846 ns | −47% |
| 三元+逻辑+`??` 链 | native | 112 ns | 85.8 ns | −23% |
| | js | 115 ns | 111 ns | −4% |
| | wasm-gc | 107 ns | 76.1 ns | −29% |
| 常量求值(折叠为单指令) | native | 22.9 ns | 50.0 ns | **+118%** |
| | js | 17.8 ns | 24.5 ns | +38% |
| | wasm-gc | 13.2 ns | 23.2 ns | +76% |
| 字符串内置链 | native | 520 ns | 540 ns | +3.7% |
| | js | 410 ns | 441 ns | +7.5% |
| | wasm-gc | 527 ns | 472 ns | −11% |
| toJSON/fromJSON 往返 | native | 839 ns | 932 ns | +11% |
| | js | 791 ns | 827 ns | +4.6% |
| | wasm-gc | 639 ns | 619 ns | −3% |

### 7.1 性能结论

1. **迭代型负载 Vm 显著领先,方向三口径一致**:过滤器(native −44%/
   −69%,wasm −17%/−39%,js ≈0/−23%)、聚合 map/filter+sum(native
   −30%/−41%)、50 项链(−55%/−47%/−23%)。来源是 v2 的原生过滤器/
   聚合循环帧与 CALLAGG 子 Program 复用——消除每元素 Evaluator
   分配,谓词越长、每元素指令越多,优势越大。此前"VM 与 Walk 持平"
   的结论是分发缺失造成的假象。
2. **微负载 Vm 落后(固定装配开销)**:常量求值 +38%(js)~+118%
   (native)、JSON 往返 +3~11%、字符串 +4~8%——每次 eval 的
   run_program 装配(VmState+栈预分配)按次计费;负载越"胖",摊销
   越充分。选型应按负载画像,而非假定 VM 恒快。
3. **宿主画像:收益 native ≥ wasm-gc > js(V8 JIT)**:JIT 把递归
   walk 优化掉大半,同时把 Vm 指令循环优势收窄(长谓词仅 −23%);
   wasm 解释器与 native 同序(−17~−47%)。与旧报告"wasm 上两引擎
   持平"的结论不同——那同样是假数据。
4. **编译端到端**:bytecode codegen 增量 js +29%(5.45→7.05µs)、
   native +4.7%、wasm ≈0;预编译后(热路径)不存在该成本。

### 7.2 稳定性对比(同一 7 场景套件,Walk 与 Vm 各自完整执行)

套件:engine_test/stability_test.mbt——`stability_suite(vm)` 把
同一组断言(引擎无关,任何引擎特有失稳表现为不对称失败)分别跑在
两引擎上,外加引擎间一致性测试(4 个代表性表达式,要求值与错误
消息逐字一致)。

| 场景 | 内容 | Walk | Vm |
|---|---|---|---|
| 1 实例隔离 | 实例 A 的 transform/运算符修改不泄漏到 B | ✅ | ✅ |
| 2 确定性 | 编译后表达式连续 500 次求值结果一致 | ✅ | ✅ |
| 3 预算不可绕过 | 100k 元素数组 filter 被共享步数预算截断 | ✅(报错一致) | ✅(报错一致) |
| 4 失败后恢复 | parse/transform/预算错误后实例仍可用 | ✅ | ✅ |
| 5 交错执行 | 200 次双实例交错 eval,无串扰 | ✅ | ✅ |
| 6 嵌套预算 | 1500 层括号优雅拒绝;199 项宽表达式正确 | ✅ | ✅ |
| 7 真实上下文 | 1000 条 JSON 记录安全求值 | ✅ | ✅ |
| 一致性 | `items[.qty>2].name ?? 'none'` 等 4 式:值/错误消息相同 | ✅(基准) | ✅ |

结论:两引擎在稳定性套件下无不对称失败;确定性、预算强制、失败
恢复、实例隔离能力均等;错误消息逐字一致由 vm_parity(207 corpus,
Err 分支比对)与稳定性场景 3/4 双重锁定。三目标(native/wasm-gc/js)
全量 168/168 含本套件。注:此前的"Vm 稳定性"运行同样受分发缺失
影响(f37f10d 前 Vm 列未真正执行),本表为修复后首次真实双引擎
结果。

复现:

    moon bench --target native -p engine_test   # native(C toolchain)
    moon bench --target js -p engine_test       # js(V8 JIT via node)
    moon bench -p engine_test                   # wasm-gc(moonrun)
    moon test --target native                   # 全量 168 回归(默认 wasm-gc)
