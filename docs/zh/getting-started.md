# 快速上手

mbel 在 MoonBit 中求值标准方言(另有经典方言(legacy))的表达式,提供两个可互换引擎与严格资源预算。求值完全同步:`eval` 与 `evalSync` 是同一操作(求值仅提供同步形式,这是有意的设计偏离,已在 parity-contract 文档化)。

## 安装

在 MoonBit 工程中加入已发布模块:

```text
moon add dimon-83/mbel@0.2.0
```

按需导入包:

```moonbit
import {
  "dimon-83/mbel/ast",
  "dimon-83/mbel/engine",
  "dimon-83/mbel/evaluator",
}
```

## 快速开始:CLI

仓库自带表达式运行器:argv[1] 为表达式,argv[2] 为可选 JSON 上下文,argv[3] 可选 `vm` 选择字节码引擎:

```text
$ moon run cmd/main -- "1 + 2 * 3"
7

$ moon run cmd/main -- "6+x*2>10 ? 'big' : 'small'" '{"x": 3}'
"big"

$ moon run cmd/main -- "age * (3 - 1)" '{"age": 36}'
72

$ moon run cmd/main -- "map(nums, # * 2)" '{"nums": [1, 2, 3, 4, 5]}'
[2,4,6,8,10]

$ moon run cmd/main -- "sum(1..100)"
5050

$ moon run cmd/main -- "reduce(nums, #acc + #, 100)" '{"nums": [1, 2, 3, 4, 5]}'
115
```

CLI 默认解析经典方言(legacy);注册了演示 transform `dbl`、`first`、`concatWith`,因此管道可用:

```text
$ moon run cmd/main -- "5|dbl|dbl"
20
```

## 快速开始:库用法

创建引擎实例、构造上下文值、求值:

```moonbit
let inst = @engine.new()

// 上下文是纯数据:名字 -> Value 的对象。JSON、map、数组、字符串、
// 数字、布尔、nil 都直接映射。
let ctx = @ast.ObjectVal([
  ("user", @ast.ObjectVal([("age", @ast.NumVal(36.0))])),
])

let v = try {
  @engine.Engine::eval_expr(
    inst,
    "user.age > 18 ? 'adult' : 'minor'",
    ctx,
  )
} catch {
  @engine.EngineErr(msg) => abort(msg)
}
// @ast.StrVal("adult")
```

三个求值入口(详见[环境与配置](environment.md)):

| 入口 | 方言/模式 | 行为 |
|---|---|---|
| `Engine::eval` | 经典方言(legacy) | JS 动态语义,兼容语料锁定 |
| `Engine::eval_expr` | 标准方言,**Eval 模式** | 类型化运行时语义,无静态检查 |
| `Engine::eval_expr_checked` | 标准方言,**Compile 模式** | 先跑静态 checker(类型错误、未知名) |

术语说明:**标准方言**指现代表达式语法(类型化语义,规格见[语言定义](language-definition.md));**经典方言(legacy)**指 v0.2 起锁定的兼容语法(JS 弱类型语义),只修不增。两种方言都可在两种执行引擎(walk-tree 树遍历解释器 / 字节码 VM)上求值,结果一致。

每个入口都可在两种引擎上运行——`Walk`(参考 tree-walk,默认)或 `Vm`(字节码)——结果与错误消息完全一致,并受实例预算约束(见[环境与配置](environment.md)→ 预算):

```moonbit
@engine.Engine::set_engine(inst, Vm)
@engine.Engine::set_limits(inst, 10000, 10000, 1000000) // 节点、深度、步数
```

## 编译一次,多次求值

编译可与求值分离:

```moonbit
let e = @engine.Engine::compile(inst, "user.age * 2") catch {
  @engine.EngineErr(msg) => abort(msg)
}
let r = @engine.Expression::eval(e, ctx) catch {
  @engine.EngineErr(msg) => abort(msg)
}
```

`Expression` 跨求值缓存解析后的 AST(Vm 模式下还缓存编译后的字节码)。每次求值在单实例内是原子的:同一实例不适合并发修改,不同实例完全隔离——并发模型与稳定性契约见仓库测试(stability 套件)。

## 下一步

- [环境与配置](environment.md) — 上下文、`$env`、预算。
- [自定义函数](functions.md) — 注册函数、transform、运算符。
- [语言定义](language-definition.md) — mbel 的标准方言。
