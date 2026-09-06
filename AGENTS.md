# Project Agents.md Guide

This is a [MoonBit](https://docs.moonbitlang.com) project.

You can browse and install extra skills here:
<https://github.com/moonbitlang/skills>

## Project Structure

- MoonBit packages are organized per directory; each directory contains a
  `moon.pkg` file listing its dependencies. Each package has its files and
  blackbox test files (ending in `_test.mbt`) and whitebox test files (ending in
  `_wbtest.mbt`).

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
