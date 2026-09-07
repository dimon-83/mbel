# mbel 用户文档(中文)

mbel 是一个 MoonBit 表达式引擎:两种表达式方言——类型化语义 + 静态检查的现代**标准方言**,与锁定的**经典方言(legacy)**(JS 动态语义);双执行引擎(walk-tree 树遍历解释器与字节码 VM)、谓词聚合与资源预算。

术语说明:**标准方言**指现代表达式语法(规格见[语言定义](language-definition.md)),其语义以参考语言基线(expr-lang v1.17.8)为准——工程对齐细节见下方开发文档。**经典方言(legacy)**是 v0.2 起锁定的兼容语法,只修不增。凡 mbel 不具备的能力均如实标注(裁剪/未实现/最接近的等价物)——不写任何愿景性内容。

页面:[快速上手](getting-started.md) · [环境与配置](environment.md) · [自定义函数](functions.md) · [Visitor](visitor.md) · [Patch](patch.md) · [语言定义](language-definition.md)。

相关开发文档:

- docs/parity-contract.md — 经典方言 parity 契约与 JS 语义陷阱(英文)。
- docs/coverage-vs-expr.md — 与参考语义的覆盖对照、实测数据、路线图状态(中文)。
- docs/expr-gap-analysis.md — 差距分析与裁剪项(中文)。
- docs/perf-report.md — 三目标性能报告 Walk vs Vm(中文)。

英文版: [docs/en](https://github.com/dimon-83/mbel/tree/main/docs/en)。
