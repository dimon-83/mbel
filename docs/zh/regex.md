# 正则表达式(`matches`)

`matches` 是正则运算符,右操作数是 [RE2](https://github.com/google/re2/wiki/Syntax)
模式,求值时翻译成 MoonBit core 正则引擎的方言。本页所有内容都以 Go 的
`regexp`(expr 自己所用的参考实现)为准,由 **222 条差分语料**在双执行引擎
(Walk 与 Vm)上实测,所以"支持面"是**测出来的**,不是写出来的。

```text
"xabcx" matches "abc"          // true  —— 搜索语义,不是整串匹配
"abc"   matches "^abc$"        // true  —— 要整串匹配就加锚点
"Ünïcode" matches "^\p{L}+$"   // true  —— Unicode 字符类
"2024-01-01" matches "^\d{4}-\d{2}-\d{2}$"   // true
"a.b"   matches "\Qa.b\E"      // true  —— 引用为字面量
```

## 运算符语义

- 优先级 20,与比较运算符同级;两个方言语义完全一致。
- **搜索语义**(与 RE2、expr 相同):模式可在主题串任意位置命中;要整串判定请用 `^…$`。
- **主题**非字符串时会转成字符串:`1 matches "1"` 为 `true`。`nil` 主题返回
  `false`(与 `contains` 一样 nil 安全),**不会**被转成 `"nil"`。
- **模式必须是字符串**:`"abc" matches 1` 报 `matches: pattern must be a string`。
- 空模式匹配一切(`"x" matches ""` 为 `true`)。
- `contains`、`startsWith`、`endsWith` 是**普通字符串运算符**,不是正则 ——
  `"a.c" contains "."` 是字面点判断。

## 支持的语法

| 构造 | 写法 | 说明 |
|---|---|---|
| 字面量 | `abc` | 隐式连接;`\.` `\*` `\\` `\n` `\t` 等转义元字符 |
| 择一 | `a\|b` | |
| 量词 | `*` `+` `?` `{n}` `{n,}` `{n,m}` | 懒惰变体 `*?` `+?` `??` `{n,m}?` |
| 分组 | `(…)` `(?:…)` `(?<name>…)` `(?P<name>…)` | Go 的两种命名分组写法都可用 |
| 锚点 | `^` `$` `\A` `\z` | `\A` 译为 `^`、`\z` 译为 `$`;`$` 是**文本末尾**(不像 JS/Python 会匹配末尾换行前) |
| 词边界 | `\b` `\B` | |
| 任意字符 | `.` | 除换行外任意字符;`(?s)` 或 `(?s:…)` 使其包含换行 |
| 字符类 | `[…]` `[^…]` `[a-z]` | 首位/末位 `-` 为字面量;`\u{…}` 范围可用(含星空字符) |
| POSIX 类 | `[[:alpha:]]` `[[:digit:]]` … | RE2 的**全部 14 个**名字;其中 `cntrl`、`graph`、`print`、`punct` 按 RE2 的 ASCII 定义展开(见下) |
| 类简写 | `\d` `\D` `\w` `\W` `\s` `\S` | 与 RE2 一致的 ASCII 集合 —— `\d` 即 `[0-9]`,故 `"٣" matches "\d"` 为 `false` |
| 十六进制转义 | `\xHH` `\x{H…}` | 译为 core 的 `\u00HH` / `\u{H…}` |
| 引用字面量 | `\Q…\E` | 其中内容按字面匹配;缺 `\E` 则引用到模式末尾 |
| Unicode 字符类 | `\p{L}` `\p{Lu}` `\p{Greek}` `\p{Han}` `\p{Any}` `\pL` `\P{…}` | 通用类别**与**脚本,类内也可用;范围表取自 Go 的 `unicode` 包 |
| 标志 | `(?i)` `(?i:…)` `(?s)` `(?s:…)` | 大小写不敏感与 dot-all,裸写(作用于剩余模式)或作用域写法 |

RE2 的 14 个 POSIX 名字是 `alnum alpha ascii blank cntrl digit graph lower
print punct space upper word xdigit`。其中 10 个 core 原生支持,另外 4 个被改写成
RE2 的 ASCII 范围,因此 `[[:punct:]]` 命中 `! " # … ~`,`[[:cntrl:]]` 命中
`\x00–\x1F` 与 `\x7F`,与 Go 完全一致。

## 明确裁剪

以下每一项都会抛出带名字的可操作错误 `invalid regex: …`,而不是"匹配出别的意思":

| 裁剪 | 原因 | 替代写法 |
|---|---|---|
| `(?m)` 多行模式 | core 无 multiline | 显式锚点,或按行拆分输入 |
| 类内的 `\D` `\W` `\S` | 需要字符类集合运算 | 对整个类取反(`[^[:digit:]]`)或显式列出集合 |
| 类内的 `\P{…}` | 同上 | 写类的补集(`[^…]`) |
| 类内的 `\Q…\E` | core 类内无引用转义 | 逐字符转义 |
| `[[:^name:]]` | core 拒绝否定式 POSIX 写法 | 写 `[^[:name:]]` |
| `(?U)` ungreedy 模式 | 无 core 等价物 | 显式写懒惰量词 |
| 生效 `(?i)` 作用域内的 `(?-i)` | core 只实现 `(?i:…)` | 拆开模式,或把大小写集合写全 |

环视(`(?=…)`、`(?!…)`、`(?<=…)`、`(?<!…)`)与反向引用(`\1`)也会被拒绝 ——
**RE2 本身同样拒绝**,所以这里是与 expr 一致,而不是偏离。`\Z`、`\G`,以及类内的
锚点/反向引用同样拒绝(core 否则会把 `[a\A]` 读成字面量 `A`)。

## 与 expr 的已知差异

两项都是有意为之、已文档化并有测试覆盖:

- **`(?i)` 只折叠 ASCII。** `"Ä" matches "(?i)ä"` 在 mbel 为 `false`、
  在 expr 为 `true`,因为 core 的大小写不敏感只处理 ASCII(Unicode 折叠需要
  折叠表)。替代写法:把候选写全(`[aAäÄ]`)或组合类别(`\p{Lu}|\p{Ll}`)。
- **接受 `\uXXXX` 与 `\u{…}`。** RE2 拒绝它们;mbel 当作码点转义接受
  (翻译层内部也产出这种形式),因此这是**超集**,不会带来"静默不同含义"。

## 错误

单一形态,点名构造并透传底层诊断:

```text
invalid regex: <模式> (<原因>)
```

```text
(?m)^a       →  invalid regex: (?m)^a (unsupported regex construct (?m): multiline mode is not supported …)
[\D]         →  invalid regex: [\D] (unsupported regex construct \D inside a character class: …)
[[:^alpha:]] →  invalid regex: [[:^alpha:]] (ParserError at position 1: Invalid POSIX character class)
a**          →  invalid regex: a** (ParserError at position 2: Unexpected character)
[z-a]        →  invalid regex: [z-a] (ParserError at position 3: Invalid character class range)
\p{Nope}     →  invalid regex: \p{Nope} (invalid regex: unknown Unicode class Nope)
```

## 缓存与资源

- 编译后的模式**按引擎实例**缓存(以模式文本为键),循环里重复的 `matches` 只编译一次。
- 缓存有容量上限:**256** 个成功模式、**64** 个失败记录
  (`regex_cache_capacity()`、`regex_failed_capacity()`);满时丢弃较旧的一半,
  使插入保持均摊 O(1)。
- 若宿主会喂入无界动态模式,可在自己认为合适的时机调用
  `Engine::clear_caches()`,而不必等引擎析构。
- 匹配是 RE2 式线性时间:没有回溯,恶意模式不会随输入规模爆炸。以**动态值**传入的
  模式没有额外的长度上限(只有缓存策略),因此不可信模式来源应与其它不可信输入同等对待。

## 翻译层如何工作

mbel 只依赖 `moonbitlang/core`,而它的正则引擎说自己的方言(POSIX 类、
`\u{…}`,没有 `\p{…}`,没有 `(?m)`)。`evaluator/regex_translate.mbt` 负责把
**存在精确等价物**的 RE2 构造改写掉,其余抛出具名错误;
`evaluator/unicode_classes.mbt` 存放由 Go 的 `unicode` 包生成的类别与脚本表 ——
所以 `\p{…}` 的一致性来自构建,而不是"祈祷版本相同"。

重新生成:

```text
python3 tools/gen_regex_mbt.py     # 语料 → expr_test 数据,经由 Go 的 regexp
cd tools/unicode_oracle && go run . ../../evaluator/unicode_classes.mbt
```

差分用例在 `tools/regex_corpus.txt`,由 `tools/regex_oracle.go` 调 Go 的
`regexp` 求值;详见 [tools/README.md](../../tools/README.md)。

## 相关

- [语言定义](language-definition.md) —— 运算符表与完整语法。
- [自定义函数](functions.md) —— 内置函数语境与方言敏感内置。

返回[文档索引](README.md)。
