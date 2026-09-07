# 语言定义

对应 expr-lang 的 [Language Definition](https://expr-lang.org/docs/language-definition) 页面,描述 mbel 实现的 expr 方言(基线:expr v1.17.8,docs commit 4b31df3)。凡与 expr 有偏离处均已标注;可机检的覆盖矩阵见 docs/coverage-vs-expr.md。

开头两点说明:

- **模式。** 以下描述 `Engine::eval_expr`(Eval 模式——动态 env,类型化运行时)与 `Engine::eval_expr_checked`(Compile 模式——同语言加静态类型错误)。legacy Jexl 方言(`Engine::eval`)是另一套 JS 化语义。
- **值。** 运行时值为 `BoolVal`、`IntVal`(int64)、`NumVal`(float64)、`StrVal`、`ArrayVal`、`ObjectVal`、`NullVal`、`UndefVal`。上下文数据(JSON)产生浮点;**整数字面量与整数运算产生 int64**。只要操作数含 `IntVal`,即按类型化语义执行。

## 字面量

- 整数:十进制、`0x` hex、`0o` 八进制、`0b` 二进制、`_` 分隔;按 int64 解析——超过 `9223372036854775807` 的值是解析错误。
- 浮点:`1.5`、`.5`、`5.`、指数 `1e9`/`1.5e-3`。
- 字符串:单双引号同一转义集——`\n \r \t \a \b \f \v \\`、引号本身、`\xNN`、`\uXXXX`、`\UXXXXXXXX`、`\u{1-6 位 hex}`、八进制 `\NNN`(≤ `\377`)。非法转义、孤立代理、越界码点为词法错误;引号串内的裸换行被拒绝。
- 原始字符串:反引号,无转义,`` ` `` 双写转义反引号,允许真实换行。
- 字节串:`b"..."` / `B'...'` —— 字节内容求值已支持(BytesVal):字节相等、`len`、索引(含负索引,出界→nil)、切片(结果仍是字节串)、聚合/过滤按 int 元素迭代、`toJSON` → base64 串(Go json 语义)、`type()` 报 `"array"`。类型名与报错文案沿用 expr 的 `[]uint8`。差异:`string(b"abc")` 输出 `97,98,99`(mbel 数组惯例;expr 是 Go 的 `[97 98 99]`)。
- 布尔 `true`/`false`;`nil`。
- 注释:`//` 行注释与 `/* */` 块注释。

## 类型与运行时类型化(expr parity)

- 两个整数做 `+ - * %` 结果仍是整数(int64,按 Go 语义回绕)。
- 任一侧为浮点则提升为浮点。
- `/` **恒为浮点除法**:`7/2 == 3.5`、`1/0 == +Inf`、`0/0 == NaN`——没有除零错误。
- `%` 仅限整数;Go 语义(符号随被除数);`% 0` 报 `integer divide by zero`。
- `**`/`^` 恒产生浮点(即使 `2 ** 3`);负指数合法。
- 数值间相等/排序会提升(`1 == 1.0` 为 true);跨类相等为 false;跨类排序与混合 `+` 在运行时(或 Compile 模式检查期)报 `invalid operation: int + string` 一类错误。
- 一元 `-` 保持操作数类型(`-5` 为 int,`-5.0` 为 float)。
- `type()` 对整数报 `"int"`;浮点报 `"number"`(expr 报 `"float"`——文档化偏离:legacy 名称被锁定)。

## 运算符

优先级从高到低(除注明外均左结合):

| 优先级 | 运算符 | 说明 |
|---|---|---|
| 100 | `**` `^`(右结合) | 幂,浮点结果 |
| 90 | 一元 `-` `+` | 比幂更松:`-2**2 = -(2**2)` |
| 60 | `*` `/` `%` | |
| 50 | 一元 `not` `!` | |
| 30 | `+` `-` | `+` 拼接字符串;其余类型不可混用 |
| 25 | `..` | 整数范围,含端点;降序为空 |
| 20 | `==` `!=` `<` `>` `<=` `>=` `in` `matches` `contains` `startsWith` `endsWith` | `not in`/`not matches`/`not contains`… = 后缀否定 |
| 15 | `&&` `and` | |
| 10 | `\|\|` `or` | |
| 0 | `\|` | 管道:`x \| f(a)` → `f(x, a)`;右侧必须带括号调用(裸 `\| f`、`\| x.m()` 是 parse error) |
| — | `??` | 优先级 500,左结合,**同一层后不能再跟运算符**:`1 ?? 2 + 3` 是解析错误,`1 + 2 ?? 3`、`(1 ?? 2) + 3` 合法,`a ?? b ?? c` 可链 |

其他语法:

- 比较链:`1 < x < 10` = `(1 < x) && (x < 10)`(仅 `< > <= >=`;`==` 不链)。
- 三元 `a ? b : c`、elvis `a ?: b`(测试为真则取测试值)。
- `if cond { seq } else { seq }` —— 两个花括号与 `else` 均必选;分支是完整序列(可含 let);`if` 只能作为表达式起点(内嵌需括号);支持 else-if 链。
- 可选链 `?.` / `?.[` —— nil 安全成员访问(mbel 下钻默认 nil 安全)。
- 切片 `a[1:3]`、`a[:2]`、`a[2:]`、负边界(`len + x`)、越界收敛、`from > to` 为空;支持数组与字符串(字符串按字符切片;expr 按字节——非 ASCII 差异已文档化)。
- `matches` 正则:MoonBit core 正则仅字面量(已文档化裁剪;完整正则在路线图上)。`contains`/`startsWith`/`endsWith` 是运算符,nil 安全(nil 操作数 → false)。
- `let x = expr; rest` 与 `a; b; c` 序列 —— `let` 出现在 prec-0 位置(顶层、括号、实参、if 分支);词法作用域,允许遮蔽(Eval 模式);序列结果为最后一项;序列/谓词代码可读外层 let。
- `$env` —— 整个上下文作为值(`len($env)`、`keys($env)`、成员访问均可用;不可声明)。

## 谓词

谓词聚合第二参为谓词;花括号可选,`.field` 是 `#.field`(当前元素)的简写:

```text
filter(users, .age >= 18)
filter(users, {.age >= 18})
map(nums, # * 2)
reduce(nums, #acc + #, 100)
count(nums, # > 2)
```

指针:`#`(当前元素)、`#index`(位置)、`#acc`(累加器)。`#index`/`#acc` 仅在定义它们的聚合内绑定;合法指针只有 `#`、`#index`、`#acc`——`#age` 是编译错误 "unknown pointer '#age'"(expr parity)。指针只能在谓词上下文使用——谓词之外(`# + 1`、`xs[#]`)是 parse error。

管道的左侧占调用第 0 参,因此第一个显式实参就是谓词:

```text
nums | map(# * 2)
users | filter(.age >= 18) | map(.name) | first()
```

mbel 额外接受 Jexl 方括号谓词 `items[.price <= 2]`(逐元素过滤,可继续链式访问)——expr 无方括号形式,`[` 后的裸 `.` 直接 parse error(已文档化的扩展,见 docs/expr-gap-analysis.md §6)。

谓词聚合(15 个):`all none any one filter map count sum find findIndex findLast findLastIndex groupBy sortBy reduce`。

## 函数

56 个内置 + 15 个聚合,清单见[自定义函数](functions.md)页面;类型化返回遵循 expr(`len`、`count`、各类下标、`int()` 为整数;`sum`/`abs`/`min`/`max` 对整数输入保持整数)。自定义函数与 transform 在引擎实例上注册(无反射——见[自定义函数](functions.md))。

## 错误与预算

- 解析错误:`parse error at L:C: message`(带源码位置)。
- Compile 模式(严格)错误采用 expr 文案:`invalid operation: + (mismatched types int and string)`、`non-bool expression (type int) used as condition`、`invalid argument for len (type int)`、`unknown name x`。
- 运行时(Eval 模式)类型错误:`invalid operation: int + string`、`integer divide by zero`、`slice bounds must be integers`。
- 预算:解析期节点/token 上限与递归护栏;求值期深度(两引擎);分配点步数预算——消息:`expression is too large (more than N nodes)`、`expression is too deeply nested`、`expression is too deep (more than N levels)`、`memory budget exceeded`。

## 与 expr 的已知差异(摘要)

- 环境只能是数据:无 struct 环境、值上无方法(反射裁剪);方法调用语法可解析但在 lowering 时报错。
- `type()` 对浮点返回 `"number"`(legacy 锁定)而非 `"float"`。
- legacy 方言中字符串 `in` 是子串语义(expr 前端 Eval 模式对字符串沿用该行为——差异已在覆盖矩阵记录)。
- 字符串切片按字符;正则仅字面量;`upper`/`lower` 仅 ASCII;时间是最小 UTC/ISO 子集;JSON 数字是 double(上下文数据中 2^53 以上整数损失精度;字面量与 int64 的 `toJSON` 输出精确)。
- 方括号谓词 `items[.expr]` 被接受(Jexl 兼容);expr-lang 无方括号形式,`[` 后的裸 `.` 直接报错。

expr 语言定义每一行的可机检状态见 docs/coverage-vs-expr.md;裁剪项与理由见 docs/expr-gap-analysis.md。
