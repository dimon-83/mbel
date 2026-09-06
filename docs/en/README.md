# mbel user documentation (English)

mbel is a MoonBit expression engine: a Jexl-compatible evaluator with an
[expr-lang](https://expr-lang.org) (v1.17.8) language front end, dual
execution engines, predicate aggregates, and resource budgets.

These pages mirror the expr-lang documentation structure and map each topic
onto mbel's actual API. Where a capability does not exist in mbel it is
stated explicitly (cut / not implemented / closest equivalent) — nothing
here is aspirational.

| Page | expr-lang original |
|---|---|
| [Getting started](getting-started.md) | https://expr-lang.org/docs/getting-started |
| [Environment & configuration](environment.md) | https://expr-lang.org/docs/environment · https://expr-lang.org/docs/configuration |
| [Custom functions](functions.md) | https://expr-lang.org/docs/functions |
| [Visitor](visitor.md) | https://expr-lang.org/docs/visitor |
| [Patch](patch.md) | https://expr-lang.org/docs/patch |
| [Language definition](language-definition.md) | https://expr-lang.org/docs/language-definition |

Related developer documentation:

- docs/parity-contract.md — Jexl parity contract and JS-semantics pitfalls (English).
- docs/coverage-vs-expr.md — coverage matrix vs expr, measurements, roadmap status (Chinese).
- docs/expr-gap-analysis.md — gap analysis and cut items (Chinese).
- docs/perf-report.md — three-target performance report, Walk vs Vm (Chinese).

Chinese version: [docs/zh](https://github.com/dimon-83/mbel/tree/main/docs/zh).
