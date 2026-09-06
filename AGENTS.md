# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

- Test-file kinds: `_test.mbt` is blackbox (public API only, in the
  `*_test` package dirs such as `engine_test/`, `expr_test/`);
  `_wbtest.mbt` is whitebox and lives inside the package it tests (e.g.
  `expr/lexer_wbtest.mbt` — used where token-level content must be seen).
  Corpus data lives in `*_test` data files, never inline.

- In the toplevel directory, there is a `moon.mod` file listing module
  metadata.

## Coding convention

- MoonBit code is organized in block style, each block is separated by `///|`,
  the order of each block is irrelevant. In some refactorings, you can process
  block by block independently.

- Try to keep deprecated blocks in file called `deprecated.mbt` in each
  directory.

## Tooling

- `moon fmt` is used to format your code properly.

- `moon ide` provides project navigation helpers like `peek-def`, `outline`, and
  `find-references`. See $moonbit-agent-guide for details.

- `moon info` is used to update the generated interface of the package, each
  package has a generated interface file `.mbti`, it is a brief formal
  description of the package. If nothing in `.mbti` changes, this means your
  change does not bring the visible changes to the external package users, it is
  typically a safe refactoring.

- In the last step, run `moon info && moon fmt` to update the interface and
  format the code. Check the diffs of `.mbti` file to see if the changes are
  expected.

- Run `moon test` to check tests pass. MoonBit supports snapshot testing; when
  changes affect outputs, run `moon test --update` to refresh snapshots.

- Prefer `assert_eq` or `assert_true(pattern is Pattern(...))` for results that
  are stable or very unlikely to change. For snapshot tests that record
  structured debugging output, derive `Debug` and use `debug_inspect`, rather
  than deriving `Show` for debugging. For solid, well-defined results (e.g.
  scientific computations), prefer assertion tests. You can use
  `moon coverage analyze > uncovered.log` to see which parts of your code are
  not covered by tests.

## Testing and verification

- Every behavior change ships with tests in the same commit; new syntax and
  semantics must enter the safety net, not just pass existing suites.

- **Dual-engine parity**: any feature reachable from the expr front end or the
  legacy dialect must run identically on Walk and Vm — same values AND same
  error messages (NaN-aware). Keep the parity suites
  (`engine_test/vm_parity_test.mbt`, stability, budget parity) green; a
  mismatch means a real dispatch bug, never a tolerated difference.

- **Three targets**: after changes touching evaluation, the value model,
  memory/serialization, or the VM, run `moon test` on all of `native`,
  `wasm-gc` and `js` (`moon test --target native|js`; default is wasm-gc).
  Budget-guard numbers are tuned for moonrun's fixed stack — lowering them is
  a security change.

- **Snapshot vs assertion**: prefer `assert_eq`/explicit expectations for
  stable results; use snapshot-style `inspect` for structured debug output.
  Beware constant folding when asserting (an expression like `42 + 1` is a
  single folded constant — assert final values, not source shapes).

- **Typed values**: `IntVal(50)` and `NumVal(50.0)` print identically, so
  assertions on evaluation results cannot see the type. Use explicit kind
  assertions (match `IntVal(_)` vs `NumVal(_)`, see `expr_test/typed_test.mbt`)
  whenever the int/float distinction matters (overflow, `/` vs `%`, `type()`).

- **Budgets**: verify budget behavior per engine (node/token limits at parse,
  `max_depth` at eval on BOTH engines, step budget at allocation points) and
  that budget error messages match the legacy wording exactly
  ("expression is too large (more than N nodes)", "expression is too deeply
  nested", "expression is too deep (more than N levels)", "memory budget
  exceeded").

## Error and semantics conventions

- The engine has three evaluation entries with distinct error contracts:
  `Engine::eval` (Jexl legacy, JS semantics), `Engine::eval_expr` (expr
  front end, Eval mode — typed runtime errors such as
  "invalid operation: int + string"), and `Engine::eval_expr_checked` (expr
  front end, Compile mode — static checker errors such as
  "invalid operation: + (mismatched types int and string)" or
  "unknown name x"). Do not blur them: Eval mode must stay dynamic, strict
  checks belong to the checked entry.

- **expr alignment**: new expr-front-end behavior must match expr-lang
  (v1.17.8) as verified against its source and probes; deviations are only
  acceptable as documented cuts (see docs/expr-gap-analysis.md and the
  divergence notes in docs/coverage-vs-expr.md).

- **Legacy isolation**: the Jexl legacy path is locked by its corpus and
  suites; shared-code changes must not alter legacy observable behavior. The
  typed-value discriminator is structural: the legacy lexer only produces
  `NumVal`, so "an operand is or contains `IntVal`" is the runtime signal
  that expr typed semantics apply — keep that property intact.

- Parse errors carry "parse error at L:C: message"; position-carrying
  checker errors (line:col with caret) are planned but not yet implemented —
  do not claim or fake them.

## Performance

- Benchmarks: `moon bench -p engine_test` (wasm-gc), add
  `--target native|js` for the other hosts; 10×N runs, mean ± σ. The current
  Walk-vs-Vm dataset lives in docs/coverage-vs-expr.md §7.

- Perf-sensitive changes (VM dispatch, evaluator hot paths) should report
  before/after bench numbers in the commit message; treat changes within σ as
  noise and say so. The per-instruction depth check is gated (zero cost at
  default budgets) — do not regress that property.

- Debugging the VM: `evaluator.disassemble(program)` prints every instruction
  with decoded constants and jump targets (see expr_test/opcode_test.mbt for
  expected output shapes).

## Workflow and contribution

- Feature work happens on the worktree branch (`feat/4.4-language-frontend`
  in `../mbel-44`), merged to `main` fast-forward only when the full safety
  net is green (see Version management). Branch names for parallel work:
  `feat/<stage>-<slug>` or `fix/<slug>`.

- Keep commits small, focused, and green (each commit passes `moon test`);
  use conventional prefixes with the stage where relevant: `feat(stage4.4.x)`,
  `fix(...)`, `docs(...)`, `refactor(...)`. Docs/metadata may land directly
  on `main`; functional code does not.

- API changes (public signatures, new entry points) must: run `moon info`
  and review the `.mbti` diff before committing; update README and
  `CHANGELOG.md` in the same change. Regenerated `.mbti` churn for
  pre-existing packages is not committed (repo convention) — only first-time
  files for new packages are tracked.

- Deprecated code moves to `deprecated.mbt` per package, with the replacement
  named in a comment.

## Dependencies and platform notes

- The module depends only on `moonbitlang/core`. Adding a dependency requires
  it to work on native/wasm-gc/js; prefer pure MoonBit implementations.
  FFI/host injection (e.g. a future regexp backend) needs an explicit,
  documented API boundary and must not break the other targets.

## Version management and releases

- Semantic versioning (SemVer). Before 1.0: a MINOR bump delivers a milestone
  (each stage-4.x landing, a new API surface); a PATCH bump ships fixes and
  documentation or behavior corrections. 1.0 is the first stable release,
  decided at the strict-engine gate (stage 4.4.5).

- `version` in `moon.mod` is the single source of truth. Release tags are
  annotated and named exactly `v<version>`; never create ad-hoc tags (the
  historical `v0.2.0-stable` at cc288c8 is drift — move it to the matching
  release commit or delete it at the next release).

- `main` is always releasable. Functional work lands on `main` only through a
  feature branch merged fast-forward after the full safety net passes
  (`moon test` on native, wasm-gc and js, parity suites included). Direct
  commits on `main` are limited to docs/metadata.

- Release checklist (run on `main`):
  1. `moon test` green on native, wasm-gc and js.
  2. Bump `version` in `moon.mod` and add a `CHANGELOG.md` entry in the same
     commit.
  3. `moon package` and inspect the publish zip.
  4. Annotated tag `v<version>` on the bump commit.
  5. `moon publish` — before the first registry publish, fill `repository`
     and `description` in `moon.mod`.

- Agent rule: never bump `version`, add a tag, or publish unless the user
  asks; when asked, keep `moon.mod`, `CHANGELOG.md` and the tag consistent in
  one commit.
