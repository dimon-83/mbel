# mbel user documentation (English)

mbel is a MoonBit expression engine: two expression dialects — a modern
**standard dialect** with typed semantics and static checking, and a locked
**classic dialect (legacy)** with JS-style dynamic semantics — dual
execution engines (walk-tree interpreter and bytecode VM), predicate
aggregates, and resource budgets.

Terminology: the **standard dialect** is the modern expression syntax
(spec: the [language definition](language-definition.md)); its semantics
follow the reference language baseline (expr-lang v1.17.8 — engineering
alignment details live in the developer docs below). The **classic dialect
(legacy)** is the v0.2-compatible syntax: locked, fixes only. Where a
capability does not exist in mbel it is stated explicitly (cut / not
implemented / closest equivalent) — nothing here is aspirational.

Pages: [Getting started](getting-started.md) ·
[Environment & configuration](environment.md) ·
[Custom functions](functions.md) · [Visitor](visitor.md) ·
[Patch](patch.md) · [Language definition](language-definition.md).

Related developer documentation:

- docs/parity-contract.md — classic-dialect parity contract and JS-semantics pitfalls (English).
- docs/coverage-vs-expr.md — coverage matrix vs the reference semantics, measurements, roadmap status (Chinese).
- docs/expr-gap-analysis.md — gap analysis and cut items (Chinese).
- docs/perf-report.md — three-target performance report, Walk vs Vm (Chinese).

Chinese version: [docs/zh](https://github.com/dimon-83/mbel/tree/main/docs/zh).
