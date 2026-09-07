# expr 语言定义覆盖对照(mbel vs expr-lang)

对照基准:https://expr-lang.org/docs/language-definition 与
expr 仓库 docs/language-definition.md(commit 4b31df3, v1.17.8)。
测试证据:mbel 219 个 test 函数(`moon test` 常规计数 198 + 21 个
bench 经 `moon bench` 运行)——lexer_test 21 / parser_test 29 /
evaluator_test 28 / expr_test 42(parser 14 · eval 17 · opcode 4 ·
typed 4 · checker 4)/expr 白盒 3(lexer_wbtest)/engine_test 96(API 26 ·
预算 7 · builtin 16 · 聚合 10 · 对拍 9 · 稳定性 3 · 预算 parity 4 ·
bench 21);三目标(native / wasm-gc / js)均 198/198;另与真实 Jexl 的差分
corpus(3360+ 表达式,byte-identical)。双引擎性能/稳定性实测见 §7。
语法层覆盖更新:2026-09-06 4.4.1(lexer)+4.4.2(parser+求值)交付,
本轮(§1-§3)❌ 行大量转 ✅;未标"4.4.x"的行已实现。

图例:✅ 已实现且有测试 | 🟡 部分/语义受限 | ❌ 未实现

## 1. 字面量与数据结构

| 特性 | 状态 | 测试证据 | 备注 |
|---|---|---|---|
| 整数(十进制) | ✅ | lexer_test (21), corpus | JS double 承载,±2^53 内精确;expr 前端另有 Int64 字面量 EInt(4.4.3 前折叠为 NumVal) |
| 浮点 | ✅ | corpus `0.1+0.2` 等 | 正确舍入解析;最短格式输出 |
| hex/oct/bin/`_` 分隔 | ✅ | lexer_wbtest, parser_test, eval_test | 0x/0o/0b 与 `_`(expr 前端词法) |
| 指数字面量 `1e9` | ✅ | parser_test `1.5e-3` | 含 `E`/`e`/符号指数 |
| `.5` 形式 | ✅ | parser_test `.5` | 仅数字起始上下文词法化为浮点(与成员 `.` 区分) |
| 字符串 '…' / "…" | ✅ | lexer_test, corpus | 单双引号同一转义集 |
| 转义 `\xNN \uXXXX \u{…}` 八进制 | ✅ | lexer_wbtest, eval_test | 含 `\UXXXXXXXX`;非法转义/孤立代理/越界码点=词法错误(expr 语义) |
| 原始字符串 `` `…` `` | ✅ | lexer_wbtest, parser_test | 反引号内无转义,`` 双写转义反引号,允许真实换行 |
| 字节串 b"…" | 🟡 | lexer_wbtest | 词法/解析 ✅(`b"…"`/`B'…'`,转义=简单集+`\xNN`+八进制≤`\377`,`\u` 拒绝,非 ASCII 按 UTF-8 编码);求值待 4.4.3 值模型(Bytes) |
| 布尔 true/false | ✅ | lexer_test | |
| nil | ✅ | eval_test `nil contains…` | nil 字面量(expr 前端)+NullVal 运行时存在 |
| 数组 [1,2,3] | ✅ | parser_test, corpus | |
| map {a:1, 'b':2} | ✅ | parser_test, corpus | key: ident/string/number/括号表达式 |
| 注释 // /* */ | ✅ | parser_test(lexer 层) | 行注释与块注释(块注释跨行计数正确) |

## 2. 运算符

| 特性 | 状态 | 测试证据 | 备注 |
|---|---|---|---|
| 算术 + - * / | ✅ | evaluator_test, corpus | JS 语义(`/` 不恒 float) |
| 整除 // | ✅ | corpus `7//2`=3 | Math.floor |
| 取模 % | ✅ | corpus | 精确 fmod(Dekker) |
| 幂 ^ | 🟡 | corpus | Jexl legacy:左结合 50;expr 前端:`^`/`**` 右结合 100(下一行) |
| ** 幂 | ✅ | parser_test, eval_test | 右结合;`-2**2`=-(2**2)(一元 90<100);负指数合法 |
| 比较 == != < <= > >= | ✅ | evaluator_test, corpus | JS loose ==;expr 严格 → 4.4.5 |
| 逻辑 && \|\| ! | ✅ | evaluator_test(短路) | 惰性求值 |
| not / and / or 词形 | ✅ | parser_test | 关键字词法;`and`/`or` 二元(15/10),`not` 一元(50)+后缀否定 |
| in / not in | ✅ / ✅ | corpus, parser_test | 后缀否定集=in/matches/contains/startsWith/endsWith;`a not in b`→`not (a in b)`;字符串上的 legacy `in` 为子串语义(expr 报错,差异记录) |
| ?? 空合并 | ✅ | eval_test | expr 混用限制已实现(`1 ?? 2 + 3` 解析报错,提示用括号);链式 `a ?? b ?? c` 合法;仅 nil/undefined 触发 |
| .. 范围 | ✅ | builtin_test | 1e6 内存预算;负边界合法,降序空 |
| 切片 [1:3] [:3] [3:] | ✅ | eval_test(双引擎) | expr 语义:负边界 len+x、越界 clamp、from>to 为空;数组+字符串(字符串按字符,mbel 注:expr 按字节,非 ASCII 差异记录) |
| 可选链 ?. /?.[ | ✅ | parser_test, eval_test `user?.name` | 求值走 nil-safe drill(与 mbel drill 语义一致) |
| 链式比较 a<b<c | ✅ | parser_test(结构) | `< > <= >=` 合取;`==`/`!=` 不链 |
| matches 正则 | 🟡 | builtin_test | MoonBit core regex=字面量;完整 RE2 → 4.5 |
| contains/startsWith/endsWith 运算符 | ✅ | eval_test, parser_test | expr 语义是**运算符**(非函数):infix、nil-safe(空操作数=false),双引擎注册 |
| 管道 \| | ✅ | parser_test, eval_test | expr 管道:`x\|f(a)` desugar 为 `f(x,a)`;RHS 必须是调用(`1\|2` 解析报错);需宿主注册函数/转换 |
| 一元 -/!(优先级) | ✅ | parser_test, eval_test | expr:一元 -/+ 90、not/! 50、幂 100 → `-2**2`=-(2**2)、`2**-2` 合法;Jexl legacy 词法负号保留 |

## 3. 表达式形式

| 特性 | 状态 | 备注 |
|---|---|---|
| 三元 ?: / Elvis ?: | ✅ | evaluator_test, corpus;expr 前端 elvis=`a ?: b`(真值取 a) |
| if/else 块 | ✅ | expr 前端(parser_test/eval_test):`if c { seq } else { seq }`——两分支花括号与 `else` 均必选,分支体=完整序列(let/嵌套 if 可用),整体是表达式(需括号嵌入);仅表达式起点接受 `if`;else-if 链递归 |
| let 声明 + ; 序列 | ✅ | expr 前端(parser_test/eval_test,双引擎):`let` 仅限 prec-0 位置(顶层/括号/参数/if 块);`x;y` 普通序列合法,结果为末值;词法作用域(内层遮蔽;Eval 模式允许重声明——checker 的"禁止重声明"待 4.4.4);谓词/过滤器可读外层 let |
| 谓词 {#…} + #/#acc/#index/省略 # | ✅ | 花括号包裹与省略形式均支持(parser_test/eval_test);`.field` 相对访问=指针成员;未知指针后缀(#age)解析报错 |
| 方法调用 foo.bar() | 🟡 语法✅ | 解析/管道目标均接受;求值=裁剪(数据值无方法,lower 报清晰错误)——expr 的 Go-reflect 方法调用对应裁剪项(§四),宿主注册函数池为替代路径 |
| $env | ✅ | expr 前端:eval_test——求值为根 ctx(用户变量视图,不含内置);成员/索引/keys/len 可用;不可声明 |
| 成员/索引/动态键 | ✅ | parser_test, corpus |
| 相对过滤器 [.x==1] | ✅ | Jexl 形式(expr 无此语法) |

## 4. 内置函数(64 个)

| 类 | 状态 | 详情 |
|---|---|---|
| 数学 8 | ✅ 8/8 | builtin_test;round=Go 半远离零 |
| 字符串 16 | ✅ 16/16 | upper/lower 仅 ASCII(差异记录) |
| 集合 12 | ✅ 12/12 | get 越界 nil;sort 数字/字符串 |
| 转换 9 | 🟡 9/9 实现 | type() 对整数返回 "int"(4.4.3);float 仍报 "number"(legacy 锁定,expr 报 "float",待 dialect 拆分);toJSON NaN→null(expr 报错);大 int64 JSON 精度损失已记录 |
| 位运算 8 | ✅ 8/8 | Int64 语义 |
| 时间 4 | 🟡 最小集 | now/duration/date(ISO)/timezone=UTC;无 time.Time 对象/方法/多 layout/时区库 |
| 谓词聚合 15 | ✅ 15/15 | 函数式调用形式已交付(2026-09-06,如 `count(list, # > 2)`):# /#index/#acc 指针、省略 # 的相对访问、子 Program+类型化槽位;`{expr}` 花括号谓词形式已随 parser 重写交付(4.4.2,双引擎一致) |

## 5. 工程能力

| 特性 | 状态 | 备注 |
|---|---|---|
| 节点上限(1e4,可配) | ✅ | budget_test |
| 嵌套上限(1000;expr 无此项,wasm 栈必需) | ✅ | budget_test |
| 求值深度 + 步数预算(跨 filter 共享) | ✅ | budget_test, stability_test, budget_parity_test | 深度预算双引擎同语义:Vm 每条指令携带源 AST 深度(program.depths),仅当 max_depth 低于程序最大深度时逐指令检查(默认预算零开销);相对过滤器谓词按「每元素新求值器」重新计深,与 Walk 一致;expr 前端 parse 应用 max_nodes(节点数,迭代统计)与递归/深度护栏(嵌套约 500-1000 层) |
| env 白名单 / Strict | 🟡 严格模式 | `eval_expr_checked`/`compile_expr_checked_limited`(4.4.4 checker 阶段1):已知类型的运算符规则按 expr Compile 文案报错(`invalid operation: + (mismatched types int and string)`、`non-bool expression (type int) used as condition`);`eval_expr` 保持 Eval 模式(动态语义,与 expr 的 Eval/Compile 双模式对齐);env 白名单=阶段 2 |
| 常量折叠 | ✅ | builtin_test fold 套件 |
| 12-pass optimizer 其余 | ❌ | 4.3 剩余(需 VM 落点) |
| 字节码 VM | ✅ v2(指令化) | 26 opcode(0-25)平行 Int 数组 + 编译期预解析 + 栈预分配 + 原生过滤器/聚合循环帧 + 词法作用域(局部变量槽/切片/env 指令,4.4.2);`Engine::set_engine(Walk \| Vm)`,默认 Walk;207 corpus + 手写用例 Walk vs Vm **真绿**(值+错误消息严格相等,NaN-aware;f37f10d 恢复端到端分发后首次为真,此前"假绿"见 §7 勘误);实测:迭代型负载 Vm 领先(过滤器 native −69% / wasm −39%,聚合 native −30~41%),微负载 Vm 落后(常量求值 +38~118%)——同批数据见 §7 |
| 编译错误 行:列\|…^ | ❌ | 4.4.1 位置信息 |
| 差分验证 harness | ✅ | tools/(expr 侧待 go 差分) |
| 并发模型 | ✅ 文档化 | wasm 单线程原子 eval;实例隔离测试 7 项 |

## 6. 剩余功能实现方案(阶段 4.3 剩余 + 4.4/4.5)

### 6.1 字节码 VM(4.3)——v1 + v2 已交付
**双引擎架构(2026-09-05/06,0010ef3/fce4d69 + 4.4.2)**:`evaluator/vm.mbt`。
26 opcode(0-25:CONST/LOADCTX/LOADREL/FETCH/CALLBINFN/CALLUNFN/
MATCHES/ANDJUMP/ORJUMP/COALESCE/JUMP/JUMPIFFALSE/ARRAY/OBJECT/
CALLFUNC/FILTERBEGIN/FILTEREND/FILTERSTATIC/LAZYBIN/LOADSLOT/
CALLAGG + 4.4.2 增 SLICE/LOADLOCAL/ADDLOCAL/POPLOCAL/ENV)编码为
平行 Int 数组(opcode+operand),常量池去重
(CVal/CAst/CKeys/CFn/CUFn/CAgg;CRaise 承载"抵达即 raise"的缺省分支);
编译期运算符预解析为直接函数引用(运行时零查找)、栈预分配+sp 指针
(编译期 max_stack 模拟)、patch 式跳转;语义函数单源
(apply_binary_op/call_pool_function/fetch_from/slice_value/
aggregate_call 由两引擎共享,指令只做调度);相对过滤器/静态索引
指令化(FILTERBEGIN/END、FILTERSTATIC),谓词聚合编译为 CALLAGG
子 Program + 单子 VM 跨元素复用(LOADSLOT 类型化槽位 #/#index/#acc),
子程序编译期继承外层 let(编译期 local_names 镜像运行时 locals,
LOADLOCAL 静态槽位解析,ADDLOCAL/POPLOCAL 维护词法作用域,ENV 推
根 ctx 供 `$env`);手动求值运算符(LAZYBIN)按需回调 tree-walk(共享
预算);CLI `argv[3]=vm` 可选。
深度预算修复(2026-09-06):Vm 运行时此前不执行 max_depth——现
Program 携带逐指令源 AST 深度(depths/max_node_depth,编译期
node_depth 记账;相对过滤器谓词按 Walk 的「每元素新求值器」重定基),
run_program 仅在 max_depth < 程序最大深度时逐指令检查,报错文案与
Walk 完全一致(expression is too deep (more than N levels))。
expr 前端 parse 预算(同日修复):eval_expr 应用实例 max_nodes(解析后
迭代统计节点数)与递归帧护栏 + AST 深度上限(≤1000 层,保护
lower/fold/eval 递归,对齐 legacy 嵌套预算;报错 too large / too
deeply nested)。证据:engine_test/budget_parity_test.mbt(4)。
剩余:Disassemble 输出。

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

### 6.2 语言层(4.4)——交付状态与收尾清单(2026-09-07 修订,逐项状态见条目 8)

1. **✅ 已交付 4.4.1 lexer(2026-09-06,expr 前端)**:数字家族(hex/oct/
   bin/_/指数/`.5`)、字符串家族(单双引号同转义集:简单转义+`\xNN`+
   `\uXXXX`+`\UXXXXXXXX`+`\u{1-6 位}`+八进制 `\NNN`;非法转义/越界码点/
   孤立代理=词法错误)、原始反引号(`` 双写)、字节串(`b"…"`/`B'…'`:
   简单转义+`\xNN`+八进制≤`\377`,`\u` 拒绝,非 ASCII 按 UTF-8 编码;
   求值待 4.4.3 Bytes)、注释 `//` `/* */`、关键字词法(and/or/not/in/
   matches/contains/startsWith/endsWith/let/if/else/nil…)、Token 携带
   line/col(错误 `行:列`)。证据:expr/lexer_wbtest(3)。
2. **✅ 已交付 4.4.2 parser 重写 + 语法求值(2026-09-06,expr 前端)**
   :Pratt/递归下降已落地为 expr/ 包(ENode+lower 桥接 legacy 双引擎),
   覆盖:完整中缀表(右结合 `**`/`^` 100、`??` 500+混用报错、`..` 25、
   链式比较合取)、一元 90/50 优先级(`-2**2`=-(2**2))、not 后缀否定
   表(5 个)、三元/elvis、if/else(必选 else,块=序列)、let+`;` 序列
   (prec-0 位置,词法作用域,**双引擎求值**:新节点
   Sequence/VariableDeclarator + VM OP_SLICE/LOADLOCAL/ADDLOCAL/
   POPLOCAL/ENV;谓词子程序继承外层 let)、`{}` 谓词块、`?.`/`?.[`、
   切片(数组/字符串,expr 边界语义)、`$env`(求值为根 ctx)、管道
   desugar。方法调用=语法支持、求值裁剪(§3 行)。证据:parser_test
   14 + eval_test 17(全部双引擎 parity)。
   原设计要点(比较链合取、?? 规则、谓词作用域、jexl-legacy 双轨)已
   随实现落定,本节保留历史记录。
3. **🟡 4.4.3 值模型类型化——核心已交付(2026-09-06,3862565)**
   :Value 增加 IntVal(Int64);expr 整数字面量→IntVal,超出 int64 为
   解析错误;共享运算符按 expr 运行时类型化(`+ - *` 整数保型+Go 回绕、
   int/float 提升、`/` 恒 float 无除零错、`%` 仅整数+integer divide by
   zero、一元负号保型、跨类相等 false/排序与混合 `+` 报 invalid
   operation、int 边界 range 出 IntVal 数组);判别器=操作数含 IntVal
   (legacy 词法只产 NumVal → legacy 测试零改动)。内置/聚合返回类型化
   已完成(2026-09-06):len/count/indexOf/lastIndexOf/findIndex/
   findLastIndex/int() 恒返 int;abs/min/max 输入驱动(int 入 int 出);
   sum 整数列表保型;toJSON 改用精确 JSON writer(int64 全精度输出,
   NaN/Inf→null)。IntVal 核心完成。**未完成:Bytes 字节串求值**(值模型
   原计划含 Bytes;当前 byte 串词法/解析 ✅,求值在 lower 报
   "byte-string values need the typed value model"——见收尾清单②)。
4. **🟡 4.4.4 checker——阶段 1 已交付(2026-09-06)**:expr/check.mbt
   Nature 推断(字面量及传播)+ 运算符类型规则,按 expr **Compile 模式**
   文案报错;接入严格入口 `Engine::eval_expr_checked`(内部委托双引擎,
   与 eval_expr 的 Eval 模式对齐 expr 的 Eval/Compile 双模式)。剩余
   阶段 2 已完成(2026-09-06):let 绑定进入作用域静态定型(遮蔽重定
   型)、同质容器元素 Nature(`[]int` vs `[]string` 相等报错)、核心内置
   静态参数检查(len/int/float/abs/字符串/聚合首参,expr 文案)、严格
   模式 env 白名单(`eval_expr_checked` 未知顶层名报 "unknown name
   x";Eval 模式保持宽松缺失→nil)。阶段 1+2 完成。**未完成:带
   `行:列` 位置的定位错误**(需 AST 位置化重构——见收尾清单④,
   AGENTS.md 明示未实现前不宣称)。
5. **🟡 4.4.5 语义切换——API 已定型并锁定(2026-09-06)**:三入口文档化——
   `Engine::eval`(Jexl legacy 方言,JS 动态语义,差分 corpus+legacy 套件锁定)、
   `Engine::eval_expr`(expr 前端 **Eval 模式**:类型化运行时,无静态检查)、
   `Engine::eval_expr_checked`(expr 前端 **Compile 模式**:4.4.4 阶段 1 checker
   先行);均可在 Walk/Vm 上执行且受预算约束;README「Dialects and evaluation
   modes」+ 本表 §3/§4/§5 行同步。**未完成:legacy 包物理拆分(独立
   moon.pkg,104 测试随迁)、Options 对齐(env 白名单、AsBool 等)——见收尾
   清单③**。
6. **✅ 已交付(4.4.2,2026-09-06)**:谓词聚合 15——filter/map/all/… 与
   groupBy/sortBy/reduce 已以共享驱动+注入 runner 交付(tree-walk 每元素
   求值器 / VM 子 Program+单子 VM 复用),见 §4 行与 §7 实测。
7. **4.5 依赖(P2/P3,评审修订)**:正则——"RE2 全特性"措辞修正(RE2 本身
   不支持反向引用;应为"正则全特性"裁剪):范围缩至**字面量/字符类/量词/
   锚点/非捕获分组**,明确不支持捕获替换、反向引用、Unicode 属性、环视;
   自实现估计上调至 2000+ 行(含解析/编译/NFA 执行,16-20d);FFI 注入宿主
   RegExp(js/wasm)为快速路径但牺牲可移植性,API 边界显式化。时间——civil
   日历(已有 days_from_civil 基础)+ 固定偏移;完整 tzdata 预留外部文件
   加载接口,可永不内置。两项均延后至核心稳定。
8. **4.4 收尾清单(2026-09-07 起逐项收尾,完成即更新)**:① 文档对齐——本节
   标题/标记/正文统一(本文);② Bytes 字节串求值(4.4.3 尾巴,对齐 expr 的
   []byte 语义);③ legacy 包物理拆分 + Options 对齐(4.4.5 剩余);④ checker
   定位错误(`行:列`+caret,需 AST 位置化重构);⑤ 4.4 gate 验收(§6.3):
   expr 官方 TestExpr 167 行 want 表全量转写 + parser/checker/optimizer
   表抽样 ≥60%(未开始)。各项状态以本节标记与提交记录为准,发布时
   CHANGELOG 同步。

### 6.3 覆盖率目标
4.4 完成后(收尾清单 ⑤):expr 官方 TestExpr 167 行 want 表全量转写 +
parser/checker/optimizer 表抽样 ≥60%;4.5 后 builtin_test 904 行对齐。

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
全量 184/184 含本套件。注:此前的"Vm 稳定性"运行同样受分发缺失
影响(f37f10d 前 Vm 列未真正执行),本表为修复后首次真实双引擎
结果。

复现:

    moon bench --target native -p engine_test   # native(C toolchain)
    moon bench --target js -p engine_test       # js(V8 JIT via node)
    moon bench -p engine_test                   # wasm-gc(moonrun)
    moon test --target native                   # 全量 184 回归(默认 wasm-gc)
