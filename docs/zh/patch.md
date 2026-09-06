# Patch

对应 expr-lang 的 [Patch](https://expr-lang.org/docs/patch) 页面。

expr 允许*在编译前修改表达式*:`ast.Patch(node, newNode)` 在 `ast.Walk` 期间就地替换节点,通过 `expr.Patch(visitor)` 编译选项接入——用于把变量替换成常量、把运算符改写成函数调用,或实现运算符重载(`expr.Operator("+", "add")`)。

**mbel 状态:无 patch API。** 没有 AST 改写 visitor 钩子,也没有安装 patcher 的编译选项。当前的优化器面只有一个内置变换:

- `@evaluator.constant_fold(ast : @ast.AstNode) -> @ast.AstNode` —— 编译期折叠纯字面量子树(`42 + 1` 变成单个 `43` 常量)。它在每条求值路径上自动运行(`Engine::eval`、`eval_expr`、`eval_expr_checked`、`Expression::eval`)。

其余 optimizer pass(expr 的 fold/inArray/filterLen/countAny/sumRange 家族)与公开改写钩子在路线图上。

## 用现有能力替代

**源码层改写。** expr AST 是普通枚举,可以构造*新*树([Visitor](visitor.md) 页的模式匹配方法)再交给管线:

```moonbit
let parsed = @expr.parse_limited("x + 1", 0)
// ... 模式匹配构造 `rewritten : @expr.ENode` ...
let lowered = @expr.lower(rewritten) // -> @ast.AstNode
```

**lower 层改写。** legacy AST 可变,且构造器公开(`@ast.literal`、`@ast.binary_expr`、`@ast.identifier`...)。示例——把标识符子树替换成字面量(expr "把变量换成常量" 的玩具版):

```moonbit
// 在遍历 @ast.AstNode 的某处:
match node.node_type {
  @ast.IdentifierNode =>
    if node.ident_name == "PI" && node.from is None {
      node.node_type = @ast.LiteralNode
      node.value = @ast.NumVal(3.14159)
    }
  _ => ()
}
```

在交给 `Engine::eval_ast`(或引擎)前修改 lower 树,效果与 expr 的 patch 阶段相同:引擎看不到 patch 前的形态。注意 `let` 序列绑定的标识符与谓词标记(`is_pred`)携带语义——改写需谨慎。

**检视而非改写。** 当目标是理解 Vm 引擎将执行什么时,反汇编编译产物:

```moonbit
let node = @expr.compile_expr("map(nums, # * 2)") // 或 Engine::compile
let prog = @evaluator.compile_program(
  @evaluator.constant_fold(node.unwrap()),
  @evaluator.default_grammar(),
)
println(@evaluator.disassemble(prog))
// 0  LOADCTX 0  ; "nums"
// 1  CALLAGG 1  ; map argc=1 pred
```

期望的反汇编形态在 `expr_test/opcode_test.mbt` 中有断言。

## 运算符重载?

expr 的 `expr.Operator("+", "add")` 把运算符重定向到函数。mbel 没有类型化运算符重载;在 legacy Jexl 方言中可以用 `add_binary_op`/`remove_op` 在实例内全局重定义运算符(见[自定义函数](functions.md)→ 自定义运算符)。在 expr 前端,运算符集合与类型化语义固定。
