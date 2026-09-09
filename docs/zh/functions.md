# 自定义函数


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

`add_transform(name, fn)` 为 `|` 语法注册管道函数(经典方言管道与标准方言管道都会 desugar 成"左侧作首参"的调用):

```moonbit
@engine.Engine::add_transform(inst, "dbl", fn(args) {
  @ast.NumVal(@evaluator.to_number(args[0]) * 2.0)
})
@engine.Engine::eval_expr(inst, "5|dbl|dbl", @ast.ObjectVal([])) // NumVal(20.0)
```

批量注册:`add_functions([...])`、`add_transforms([...])`;查询:`get_function(name) -> Fn?`、`get_transform(name) -> Fn?`。

## 表达式定义函数(JSON 文件)

闭包注册要求你能写 MoonBit;**表达式定义函数**把这一能力开放给数据:函数体本身是一段表达式源码,从结构化定义(JSON 文件)加载注册。

```moonbit nocheck
// params 省略时,自动从函数体抽取自由标识符作为参数表
let resolved = @engine.Engine::add_expression_functions(
  inst,
  [{ name: "tax", params: None, body: "price * rate" }],
  None,
)
// resolved == [("tax", ["price", "rate"])]

@engine.Engine::eval_expr(inst, "tax(100, 0.13)", @ast.ObjectVal([]))
@engine.Engine::eval_expr(inst, "100 | tax()", @ast.ObjectVal([])) // 标准管道
@engine.Engine::eval(inst, "100|tax", @ast.ObjectVal([]))          // 经典管道
```

- **双池注册**:`f(x)`、标准管道 `x | f()`、经典管道 `x | f` 三种写法都可用。
- **参数自动抽取**(引擎助手 `user_function_params(name, body)` 可单独调用):函数体经标准方言前端编译并常量折叠后,收集自由标识符——排除 let 绑定名、调用 callee、成员下钻根(`a.b` 的 `a`)、相对谓词标识符(`.price`)与 `$env`,按首现顺序去重。
- **env 缺省回退**:第三参 `defaults` 传对象(通常是本次求值的 env)时,函数体上下文 = defaults 键值 + 位置实参按参数名覆盖——env `{price:200, rate:0.5}` 下 `tax()` 得 `100`,`tax(80)` 得 `40`;传 `None` 则参数纯词法,未传即 undefined。
- **校验原子**:名字必须是合法标识符(禁 13 个关键字、禁 `$env`)、禁与 15 个聚合同名(聚合分发先于函数池,同名注册永远调不到)、定义内重名拒绝;body 编译错误带 `function "名":` 前缀。任何一处失败则什么都不注册。普通内置名允许覆盖(upsert,同 `add_function`)。
- **求值语义**:函数体在注册它的实例上按当前引擎(Walk/Vm)求值,Vm 字节码按函数缓存;错误带 `function "名":` 前缀上抛。每次调用的深度/步数预算重新计数(与闭包注册一致),因此递归只受宿主栈限制——请自行保证终止。

### 函数文件格式 v1(playground)

playground「🧩 自定义函数」卡片加载 UTF-8 JSON(示例见 `playground/functions.example.json`):

```json
{
  "version": 1,
  "functions": [
    { "name": "double", "params": ["x"], "body": "x * 2", "description": "翻倍" },
    { "name": "tax", "body": "price * rate", "description": "params 省略,自动抽取" }
  ],
  "env": { "price": 200, "rate": 0.5 }
}
```

| 字段 | 规则 |
| --- | --- |
| `version` | 必填,仅接受 `1` |
| `functions` | 必填数组(可为空) |
| `functions[].name` | 必填,合法标识符,非关键字/聚合/`$env`,文件内唯一 |
| `functions[].params` | 可省略(自动抽取);字符串数组,元素为合法非关键字标识符且不重复 |
| `functions[].body` | 必填,标准方言表达式 |
| `functions[].description` | 可选,展示在函数卡片提示里 |
| `env` | 可选对象,**页面级示例环境**:载入文件时由页面填进「环境变量」框,引擎本身忽略 |

未知字段一律拒绝(防笔误);校验失败不产生半注册状态,错误消息带 `functions[i]` 索引定位。

**持久化语义**:wasm 无状态——每次导出调用都新建引擎,应用重启后自定义函数**不会**自动加载。playground 把文件内容存入 localStorage 并在页面加载时自动恢复;嵌入 mbel.wasm 的应用需自行持久化该 JSON,并在每次调用 `eval_with_functions(code, env, funcs_json, mode, engine)` 时随请求传入(`mode` ∈ `eval`/`checked`/`legacy`)。使用 MoonBit API 的宿主没有这个问题:Engine 实例常驻,注册一次长期有效。

## 自定义运算符

经典方言的 grammar 可逐实例扩展:

- `add_binary_op(operator, precedence, f)` — 急切操作数(两侧都是值)。
- `add_binary_op_manual(operator, precedence, f)` — 惰性操作数(`(Lazy, Lazy) -> Value`),用于短路运算符。
- `add_unary_op(operator, f)` — 一元运算符(优先级固定为极高)。
- `remove_op(operator)` — 从该实例移除元素/运算符。

标准方言的运算符集合是固定的(见[语言定义](language-definition.md)→ 运算符);自定义运算符是 legacy 方言能力。

## 内置库

实例创建时已种子化内置库(56 个函数)+ 15 个谓词聚合;完整清单见 README 的内置函数一节与[语言定义](language-definition.md)→ 函数。

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

- 函数池中的名字在标准方言与经典方言中都可调用。
- 聚合名在池查找之前被拦截——不要用 `add_function` 遮蔽(例如注册 `"map"` 不会影响聚合分发)。
- 回调在一次求值内同步执行;回调必须终止(预算只对分配计费,不计回调 CPU 时间),且不得并发重入同一实例(并行请用不同实例)。
