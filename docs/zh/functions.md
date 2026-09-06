# 自定义函数

对应 expr-lang 的 [Functions](https://expr-lang.org/docs/functions) 页面。

在 expr 中,自定义函数来自环境(struct 方法或 map 值)或 `expr.Function(name, fn, ...类型提示)`。mbel 没有 Go 函数与反射,因此等价物是**在引擎实例上注册**:函数、transform、运算符都是按名字注册的 MoonBit 闭包。没有类型提示——参数以动态类型 `@ast.Value` 到达,由回调自行转换。

## 注册函数

`add_function(name, fn)` 把函数放入函数池(两种方言都可调用):

```moonbit
@engine.Engine::add_function(
  inst,
  "double",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
  },
)

@engine.Engine::eval_expr(inst, "double(21)", @ast.ObjectVal([])) // NumVal(42.0)
```

回调类型为 `Fn = (Array[@ast.Value]) -> @ast.Value raise EvalError`。抛 `@evaluator.EvalErr("...")` 即可把错误上抛:

```moonbit
@engine.Engine::add_function(
  inst,
  "positive",
  fn(args : Array[@ast.Value]) -> @ast.Value {
    let x = @evaluator.to_number(args[0])
    if x < 0.0 {
      raise @evaluator.EvalErr("positive: argument must be >= 0")
    }
    @ast.NumVal(x)
  },
)
```

`evaluator` 包提供转换与格式化助手:`to_number(v)`、`to_string(v)`、`truthy(v)`、`value_equal(a, b)`,以及类型化值种类(`IntVal` 整数、`NumVal` 浮点——见[语言定义](language-definition.md)→ 类型)。注意类型化信号:若参数是(或包含)`IntVal`,运算符即按 expr 类型化语义执行;你的函数可返回 `@ast.IntVal` 保持整数(溢出按 int64 回绕),或返回 `@ast.NumVal` 表示浮点。

## Transforms(管道)

`add_transform(name, fn)` 为 `|` 语法注册管道函数(legacy Jexl 管道与 expr 管道都会 desugar 成"左侧作首参"的调用):

```moonbit
@engine.Engine::add_transform(inst, "dbl", fn(args) {
  @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
})
@engine.Engine::eval_expr(inst, "5|dbl|dbl", @ast.ObjectVal([])) // NumVal(20.0)
```

批量注册:`add_functions([...])`、`add_transforms([...])`;查询:`get_function(name) -> Fn?`、`get_transform(name) -> Fn?`。

## 自定义运算符

legacy Jexl grammar 可逐实例扩展:

- `add_binary_op(operator, precedence, f)` — 急切操作数(两侧都是值)。
- `add_binary_op_manual(operator, precedence, f)` — 惰性操作数(`(Lazy, Lazy) -> Value`),用于短路运算符。
- `add_unary_op(operator, f)` — 一元运算符(优先级固定为极高)。
- `remove_op(operator)` — 从该实例移除元素/运算符。

expr 前端的运算符集合是固定的(见[语言定义](language-definition.md)→ 运算符);自定义运算符是 legacy 方言能力。

## 内置库

实例创建时已种子化内置库(56 个函数)+ 15 个谓词聚合;完整清单见 README 的 "expr-lang builtins" 一节与[语言定义](language-definition.md)→ 函数。

- 数学(8):abs ceil floor round max min mean median
- 字符串(15):trim trimPrefix trimSuffix upper lower split splitAfter replace repeat join indexOf lastIndexOf hasPrefix hasSuffix string
- 集合(12):len first last get take keys values reverse uniq concat flatten sort
- 转换(9):int float type toJSON fromJSON toBase64 fromBase64 toPairs fromPairs
- 位运算(8):bitand bitor bitxor bitnand bitnot bitshl bitshr bitushr
- 时间(4,最小集):now duration date timezone
- 谓词聚合(15):all none any one filter map count sum find findIndex findLast findLastIndex groupBy sortBy reduce

若干内置按 expr 语义返回类型化整数:`len`、`count`、`indexOf`、`lastIndexOf`、`findIndex`、`findLastIndex`、`int()`,以及整数输入保持整数的 `abs`/`min`/`max`/`sum`。

**聚合是语言层能力,不可用户注册**:聚合集合按名字固定;谓词参数在解析期识别(`#`、`#index`、`#acc`)。若需要新的聚合式函数,注册普通函数并传入预计算数组,或提 issue。

## 调用约定注意事项

- 函数池中的名字在 expr 前端与 legacy 方言中都可调用。
- 聚合名在池查找之前被拦截——不要用 `add_function` 遮蔽(例如注册 `"map"` 不会影响聚合分发)。
- 回调在一次求值内同步执行;回调必须终止(预算只对分配计费,不计回调 CPU 时间),且不得并发重入同一实例(并行请用不同实例)。
