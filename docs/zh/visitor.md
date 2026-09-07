# Visitor


expr 提供 `ast.Walk(node, visitor)` —— 单个 `Visit(*ast.Node)` 回调会为解析后 AST 的每个节点调用,典型用途是编译前后做分析(收集标识符、静态检查)。

**mbel 状态:无 visitor API。** 没有 AST 遍历/访问工具,编译产物也没有 `program.Node()` 之类的等价物。现有替代:

- `@expr.dump(@expr.parse(src))` —— 把 expr AST 渲染成紧凑 s-表达式字符串(`bin(+,int:1,int:2)`、`call(id:filter,id:xs,pred(...))`),测试套件用它断言结构;大量示例见 `expr_test/parser_test.mbt`。
- `@evaluator.constant_fold(ast)` —— 唯一内置 AST 变换(编译期字面量折叠),作用于 *lower 后* 的 AST。
- `@evaluator.disassemble(program)` —— 渲染编译后的字节码;用于查看 Vm 引擎将执行什么(见 [Patch](patch.md))。
- 结构相等助手 `@ast.ast_equal` / `@ast.value_equal`,用于对树写断言。

## 自己写遍历

expr AST 是普通递归枚举(`@expr.ENode`,所有变体公开),visitor 只需几行模式匹配。示例:收集表达式用到的全部标识符:

```moonbit
fn collect_idents(n : @expr.ENode) -> Array[String] {
  let out : Array[String] = []
  fn go(node : @expr.ENode) -> Unit {
    match node {
      @expr.EIdent(name) => out.push(name)
      @expr.EMember(b, _, _) => go(b)
      @expr.EIndex(b, i) => {
        go(b)
        go(i)
      }
      @expr.EBinary(_, l, r) => {
        go(l)
        go(r)
      }
      @expr.EUnary(_, x) => go(x)
      @expr.ECond(t, c, a) => {
        go(t)
        match c {
          Some(x) => go(x)
          None => ()
        }
        match a {
          Some(x) => go(x)
          None => ()
        }
      }
      @expr.ELet(_, v, rest) => {
        go(v)
        go(rest)
      }
      @expr.ESeq(items) => {
        for x in items {
          go(x)
        }
      }
      @expr.EArray(xs) => {
        for x in xs {
          go(x)
        }
      }
      @expr.ECall(callee, args) => {
        go(callee)
        for a in args {
          go(a)
        }
      }
      @expr.EPred(inner) => go(inner)
      _ => () // 字面量、指针等(叶节点)
    }
  }
  go(n)
  out
}
```

节点集合与标准方言一致:字面量(`ENil`、`EBool`、`EInt`、`EFloat`、`EStr`、`EBytes`)、`EIdent`、`EMember`、`EIndex`、`ESlice`、`ECall`、`EPred`、`EArray`、`EMap`、`EUnary`、`EBinary`、`ECond`(三元、elvis、if/else)、`ELet`、`ESeq`、`EPointer`。

把分析接入管线:用 `@expr.parse_limited(src, max_tokens)` 解析(token 预算守护资源),在 lower 前遍历 `ENode`。

## 注意:lower 后 AST ≠ expr AST

标准方言前端会把 `ENode` *lower* 成引擎执行的 legacy AST(`@ast.AstNode`)。遍历 lower 树可行,但节点类型不同(`@ast.BinaryExpressionNode`、`@ast.FilterExpressionNode`、`@ast.FunctionCallNode`,以及标准方言新增的 `SequenceNode`、`VariableDeclaratorNode`、`SliceNode`)。若分析针对源码语法,遍历 `ENode`;若针对执行形态,遍历 lower 树或反汇编输出。

通用 visitor/walker API(镜像 `ast.Walk`)是可能的未来增强;上面内容已覆盖当前需求,无需新 API。
