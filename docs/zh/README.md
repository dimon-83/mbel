# mbel 用户文档(中文)

mbel 是一个 MoonBit 表达式引擎:Jexl 兼容求值器 + [expr-lang](https://expr-lang.org)(v1.17.8)语言前端,双执行引擎、谓词聚合与资源预算。

本组页面镜像 expr-lang 官方文档结构,把每个主题映射到 mbel 的真实 API。凡 mbel 不具备的能力均如实标注(裁剪/未实现/最接近的等价物)——不写任何愿景性内容。

| 页面 | expr-lang 原文 |
|---|---|
| [快速上手](getting-started.md) | https://expr-lang.org/docs/getting-started |
| [环境与配置](environment.md) | https://expr-lang.org/docs/environment · https://expr-lang.org/docs/configuration |
| [自定义函数](functions.md) | https://expr-lang.org/docs/functions |
| [Visitor](visitor.md) | https://expr-lang.org/docs/visitor |
| [Patch](patch.md) | https://expr-lang.org/docs/patch |
| [语言定义](language-definition.md) | https://expr-lang.org/docs/language-definition |

相关开发文档:

- docs/parity-contract.md — Jexl parity 契约与 JS 语义陷阱(英文)。
- docs/coverage-vs-expr.md — 与 expr 的覆盖对照、实测数据、路线图状态(中文)。
- docs/expr-gap-analysis.md — 差距分析与裁剪项(中文)。
- docs/perf-report.md — 三目标性能报告 Walk vs Vm(中文)。

英文版: [docs/en](https://github.com/dimon-83/mbel/tree/main/docs/en)。
