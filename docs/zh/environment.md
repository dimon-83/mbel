# 环境与配置

对应 expr-lang 的 [Environment](https://expr-lang.org/docs/environment) 与 [Configuration](https://expr-lang.org/docs/configuration) 页面。

在 expr 中,"环境"是带类型的(Go struct 或 map),配置是编译期选项集合。mbel 只有**一种数据环境**——普通的 `@ast.Value`,通常是对象;配置放在引擎实例上。文末对照表给出 expr 各选项在 mbel 的状态。

## 环境即数据

每次求值接收一个上下文值。没有 struct 环境,没有反射:成员访问、索引、遍历只作用于数据对象与数组(Go 反射是已文档化的裁剪——env 值不能携带方法,因此数据值上的方法调用不受支持)。

用 MoonBit 值构造上下文:

```moonbit
let ctx = @ast.ObjectVal([
  ("name", @ast.StrVal("Archer")),
  ("age", @ast.NumVal(36.0)),
  ("tags", @ast.ArrayVal([@ast.StrVal("agent"), @ast.StrVal("spy")])),
  ("nil_v", @ast.NullVal),
])
```

或从 JSON 文本解析(CLI 上下文,或 `@builtin.json_to_value`):

```moonbit
let j = @json.parse("{\"user\": {\"age\": 36}}") catch { _ => abort("bad json") }
let ctx = @builtin.json_to_value(j) // ObjectVal[("user", ObjectVal[("age", NumVal 36.0)])]
```

JSON 映射:`null` → `NullVal`,数字 → 浮点 `NumVal`,字符串/布尔/数组/对象 1:1 映射。JSON 数字是 double,因此上下文中超过 2^53 的整数会损失精度;精确整数来自整数字面量与整数运算(见[语言定义](language-definition.md)→ 类型)。

表达式内:

```text
name          # 上下文键查找            -> "Archer"
user.age      # 成员访问                 -> 36
tags[0]       # 数组下标                 -> "agent"
user["age"]   # 字符串下标               -> 36
'agent' in tags                               -> true
$env          # 整个上下文作为一个值
len($env)     # 上下文键的数量
```

`$env` 求值为根上下文(仅用户变量——内置不在其中)。`let` 绑定在其作用域内遮蔽上下文键。

## 缺失键:Eval 模式 vs Compile 模式

- `Engine::eval_expr`(Eval 模式,对应 expr 的 `expr.Eval`):缺失键求值为 nil/undefined——动态、不报错:`missing ?? "fallback"` → `"fallback"`。
- `Engine::eval_expr_checked`(Compile 模式,对应 expr 的 `expr.Compile`):checker 校验每个顶层标识符必须能解析到上下文键、注册的函数/transform/聚合或 `let` 绑定;否则报 `unknown name <name>`(expr 文案)。对可能缺席的名字,在上下文中显式放入键(可为 nil)。
- `Engine::eval`(legacy Jexl 方言):JS 语义——缺失键为 undefined,比较与下钻按 JavaScript 行为。

## 实例状态与隔离

每个 `Engine` 拥有自己的 grammar:运算符/函数/transform 注册表与缓存。修改只影响该实例:

```moonbit
let a = @engine.new()
let b = @engine.new()
@engine.Engine::add_transform(a, "shout", fn(args) { ... })
@engine.Engine::remove_op(a, "+")

@engine.Engine::eval(a, "\"hey\"|shout", ctx) // 可用
@engine.Engine::eval(b, "1+2", ctx)           // 可用(b 不受影响)
```

单实例内求值是原子的——求值过程中不存在挂起点——因此并发模型是:**并行发生在实例之间**(如每 worker 一个实例),绝不共享一个实例。注册的回调同步执行;回调内不得在求值中阻塞于异步 I/O。

## 预算(资源限制)

每个实例带三个预算,用 `Engine::set_limits(max_nodes, max_depth, max_steps)` 设置;`0` 关闭该项。默认:节点 10000、深度 10000、步数 1000000。

| 预算 | 执行点 | 失败消息 |
|---|---|---|
| `max_nodes` | 解析期:表达式节点/token 上限(legacy 与 expr 前端;expr 前端按 AST 节点计,另有递归/嵌套护栏) | `expression is too large (more than N nodes)` / `expression is too deeply nested` |
| `max_depth` | 求值期,**两引擎一致**(tree-walk 递归;字节码携带逐指令源 AST 深度) | `expression is too deep (more than N levels)` |
| `max_steps` | 求值期分配点(数组、对象、range、切片、过滤器) | `memory budget exceeded` |

Range 另有 1e6 元素硬上限。解析预算保护 MoonBit 固定 wasm 栈:过深嵌套(括号/一元链)、超大程序、超出 int64 的整数字面量都在解析期被拒绝。

## 配置选项:expr vs mbel

expr 选项 | mbel 状态
---|---
`expr.Env(env)` 类型化 struct/map 环境 | 无 struct 环境。上下文永远是数据(`@ast.Value`);见[环境即数据](#环境即数据)
`expr.AllowUndefinedVariables` | 即 Eval 模式的默认行为;严格入口(`eval_expr_checked`)按上下文校验名字——需要放行就加 nil 键
`expr.AsBool/AsInt/AsFloat64/AsAny/AsKind` 返回类型断言 | 无编译期返回类型断言。结果即引擎类型化值(`@ast.Value`);用 `type()` 或 kind 匹配
`expr.WithContext("ctx")` | 不可用(无用户函数上下文注入)
`expr.ConstExpr("fib")` 编译期求值 | 部分:引擎自动对纯字面量子树做常量折叠(`evaluator.constant_fold`);无逐函数 opt-in 标记
`expr.Patch(...)` AST 改写 | 不可用——见 [Patch](patch.md)
`expr.Timezone(...)` / 时区对象 | 最小集:`now()`、`duration()`、`date()`(ISO)、`timezone()` = UTC;无 time.Time 对象与 tzdata(已文档化裁剪)
`expr.Optimize`(12 pass) | 仅常量折叠;其余 optimizer pass 在路线图上
`expr.MaxNodes` | `set_limits(max_nodes, ...)`(默认 10000)
内存预算(1e6 单位) | `set_limits(..., max_steps)` 在分配点计费

上述每一项偏离的理由记录在 docs/expr-gap-analysis.md。
