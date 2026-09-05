# expr 语言定义覆盖对照(mbel vs expr-lang)

对照基准:https://expr-lang.org/docs/language-definition 与
expr 仓库 docs/language-definition.md(commit 4b31df3, v1.17.8)。
测试证据:mbel 136 个测试(lexer 21 / parser 29 / evaluator 28 /
Jexl API 26 / 预算 7 / builtin+运算符 16 / bench 8 / 稳定性 7)+ 与
真实 Jexl 的差分 corpus(3360+ 表达式,byte-identical)。

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
| 谓词 lambda {#…} + #/#acc/#index/省略 # | ❌ | 4.4.2(谓词聚合前置) |
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
| 谓词聚合 15 | ❌ | all/none/any/one/filter/map/count/sum/find*/groupBy/sortBy/reduce — 依赖 4.4.2 谓词语法 |

## 5. 工程能力

| 特性 | 状态 | 备注 |
|---|---|---|
| 节点上限(1e4,可配) | ✅ | budget_test |
| 嵌套上限(1000;expr 无此项,wasm 栈必需) | ✅ | budget_test |
| 求值深度 + 步数预算(跨 filter 共享) | ✅ | budget_test, stability_test |
| env 白名单 / Strict | ❌ | 4.4.4(Jexl 缺失键→undefined) |
| 常量折叠 | ✅ | builtin_test fold 套件 |
| 12-pass optimizer 其余 | ❌ | 4.3 剩余(需 VM 落点) |
| 字节码 VM | ❌ | 见 §6 方案 |
| 编译错误 行:列\|…^ | ❌ | 4.4.1 位置信息 |
| 差分验证 harness | ✅ | tools/(expr 侧待 go 差分) |
| 并发模型 | ✅ 文档化 | wasm 单线程原子 eval;实例隔离测试 7 项 |

## 6. 剩余功能实现方案(阶段 4.3 剩余 + 4.4/4.5)

### 6.1 字节码 VM + compiler(4.3 剩余,~10-14d)
- 新包 `compiler/`(AST→指令)与 `vm/`(栈机):指令集先取 expr 的核心 30-40 个
  opcode 子集:Const/True/False/Nil/Pop/Dup、Load/StoreVar(let)、LoadFast(上下文
  字段索引)、GetIndex/GetSlice、Add..Mod/FloorDiv/Pow、Eq..Le、In、Matches(常量池
  正则)、Range、Jump/JumpIfFalse/JumpIfTrue(短路 + 三元 + ??)、Call0..N/
  CallBuiltin1、LoadEnv、Arr/Map 构建、IterBegin/Next/IterEnd(谓词循环,4.4.2 后)。
- 常量池去重、变量槽、函数池索引;`Program{bytecode, constants, source}` +
  Disassemble()(对齐 expr 的可反汇编产物)。
- eval_binary 的短路/手动求值 op 以 Jump 指令化;BudgetCell 转为 VM 步数记账
  (memGrow 对应 Arr/Map/Range/Sort)。
- 验收:全部 136 测试语义等价(新增 vm_test 对拍 tree-walk)+ 自基准(fold 后
  常量路径应到 ns;整体预期 3-10× 于 tree-walk)。

### 6.2 语言层(4.4,~35-50d,gate 后启动)
1. **4.4.1 lexer(3-4d)**:数字家族(hex/oct/bin/_/exp/`x.y`)、字符串家族
   (原始/字节/\u{}/八进制)、注释、关键字词法(in/and/or/not/matches/contains/
   startsWith/endsWith/let/if/else)、Token 增加 offset/line/col(file.Source)。
2. **4.4.2 parser 重写(10-14d)**:Pratt/递归下降替换状态机(状态机无法自然表达
   块/序列/谓词)。AST 新节点:MemberNode(method?)/ChainNode/OptionalChain/
   SliceNode/RangeNode/PredicateNode/PointerNode(#/#acc/#index)/IfNode/
   VariableDeclaratorNode/SequenceNode/IntegerNode/FloatNode。要点:比较链合取、
   ?? 混用报错、not 后缀否定表、`-2^2`=-(2^2)(一元 90 < 幂 100)、谓词作用域
   深度计数(与 Jexl corpus 的回归通过 jexl-legacy 包双轨保证)。
3. **4.4.3 值模型类型化(5-8d)**:Value 增 IntVal(Int64)/保留 NumVal(float)、
   BytesVal;AST 节点 Nature 标注(type/setType);`/` 恒 float、`%`/`..` 仅整数、
   数字提升。Jexl legacy 引擎继续用现 Value。
4. **4.4.4 checker(12-18d)**:Nature 推断(运算符规则表、内置泛型特判、env
   白名单严格/宽松)、错误 `行:列 | expr | ....^`、AsBool/AsInt 期望检查。
5. **4.4.5 语义切换(4-6d)**:新顶层 `mbel::expr` API(Compile/Run/Eval + Options
   对齐:expr.Env→数据 Value、Optimize、MaxNodes、AsBool…);Jexl+JS 语义层降级
   为 legacy 包(104 测试锁定)。
6. **谓词聚合 15(4-6d,依赖 4.4.2)**:filter/map/all/… 以 PredicateNode 特化
   (tree-walk 先行,VM 循环指令随后);groupBy/sortBy/reduce 同批。
7. **4.5 依赖(5-10d)**:完整正则——自实现 RE2 子集(字面量/字符类/量词/锚点/
   分组+捕获/alternation,~800-1200 行,expr builtin_test 正则用例为验收)或
   wasm/js FFI 注入宿主 RegExp;时间——自实现 civil 日历(已有 days_from_civil
   基础)+ 固定偏移时区表,完整 tzdata 列为裁剪项。

### 6.3 覆盖率目标
4.4 完成后:expr 官方 TestExpr 167 行 want 表全量转写 + parser/checker/optimizer
表抽样 ≥60%;4.5 后 builtin_test 904 行对齐。
