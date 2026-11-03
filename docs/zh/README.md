# mbel 用户文档(中文)

mbel 是一个 MoonBit 表达式引擎:两种表达式方言——类型化语义 + 静态检查的现代**标准方言**,与锁定的**经典方言(legacy)**(JS 动态语义);双执行引擎(walk-tree 树遍历解释器与字节码 VM)、谓词聚合与资源预算。

术语说明:**标准方言**指现代表达式语法(规格见[语言定义](language-definition.md)),其语义以参考语言基线(expr-lang v1.17.8)为准——工程对齐细节见下方开发文档。**经典方言(legacy)**是 v0.2 起锁定的兼容语法,只修不增。凡 mbel 不具备的能力均如实标注(裁剪/未实现/最接近的等价物)——不写任何愿景性内容。

页面:[快速上手](getting-started.md) · [环境与配置](environment.md) · [自定义函数](functions.md) · [正则表达式](regex.md) · [Visitor](visitor.md) · [Patch](patch.md) · [语言定义](language-definition.md) · [嵌入宿主应用](wasm-embedding.md)。

相关开发文档:

- [提案 0001:面向无状态嵌入方的表达式定义函数](../proposals/0001-user-functions-for-embedders.md)(草案,英文)。
- [提案 0003:可移植 C-ABI wasm 产物与宿主易用性缺口](../proposals/0003-portable-c-abi-and-host-ergonomics.md)(草案,英文)——现有产物为何只能在 JS 宿主上跑,非 JS 嵌入方需要什么。
- docs/parity-contract.md — 经典方言 parity 契约与 JS 语义陷阱(英文)。
- docs/coverage-vs-expr.md — 与参考语义的覆盖对照、实测数据、路线图状态(中文)。
- docs/expr-gap-analysis.md — 差距分析与裁剪项(中文)。
- docs/perf-report.md — 三目标性能报告 Walk vs Vm(中文)。

英文版: [docs/en](https://github.com/dimon-83/mbel/tree/main/docs/en)。
