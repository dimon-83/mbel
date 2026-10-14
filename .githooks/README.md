# Git Hooks

## Pre-commit Hook

This pre-commit hook performs automatic checks before finalizing your commit.

### What it runs

| Step | Why |
| --- | --- |
| `moon check` | Compilation errors, including the lint-as-error rules the toolchain promotes |
| `moon test` | The full suite on the default target (wasm-gc) |

It deliberately does **not** run `moon fmt`: the pinned toolchain's formatter
rewrites unrelated files (it migrates `Int` to `Int32`, among other things), so
wiring it into the gate would produce large unrelated diffs.

It also does **not** run the other two targets — that is CI's job
(`.github/workflows/ci.yml` runs wasm-gc, js and native on every push to `main`
and every pull request). This split keeps a commit reasonably quick while the
mandatory three-target matrix still gets enforced before anything lands.

Skip it for a work-in-progress commit with `git commit --no-verify`.

### Usage Instructions

To use this pre-commit hook:

1. Make the hook executable if it isn't already:
   ```bash
   chmod +x .githooks/pre-commit
   ```

2. Configure Git to use the hooks in the .githooks directory:
   ```bash
   git config core.hooksPath .githooks
   ```

   This is a per-clone setting and is **not** carried by the repository: a fresh
   clone has no commit gate until the command above is run. Verify with
   `git config core.hooksPath`.

3. The hook will automatically run when you execute `git commit`
