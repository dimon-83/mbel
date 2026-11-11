# Third-party notices

mbel's own work is distributed under the Apache License 2.0 (see
[LICENSE](LICENSE)). This file records the third-party material the
module redistributes, together with the terms that apply to it.

## expr-lang/expr

- Project: expr-lang/expr — <https://github.com/expr-lang/expr>
- Transcribed revision: `4b31df3a2e0eefec04c017a82a00e0f08541d3e4`
  (eight commits after tag `v1.17.8`; this is the revision recorded as
  the alignment baseline in `docs/expr-gap-analysis.md`)
- License: MIT
- Copyright: Copyright (c) 2018 Anton Medvedev

### Covered material

| mbel file | Upstream source | Transcribed content |
| --- | --- | --- |
| [`expr_test/want_table_test.mbt`](expr_test/want_table_test.mbt) | `expr_test.go`, `TestExpr` want table | 167-row expression/expected-value table; 148 rows are transcribed and exercised, 19 are documented skips (see the file header) |
| [`expr_test/checker_ok_test.mbt`](expr_test/checker_ok_test.mbt) | `checker/checker_test.go`, `TestCheck` | 112-row "must compile cleanly" table; 107 rows are transcribed and exercised, 5 are documented skips |

What is transcribed is the upstream test fixtures: the expression source
strings and their expected values. The MoonBit material around them —
the environment mirror of `mock.Env`, the canonical JSON serializer, the
dual-engine harness, the `r###` row labels and the skip documentation —
is original mbel work and remains under Apache-2.0.

Because those two files combine Apache-2.0 material with MIT material,
each carries `SPDX-License-Identifier: Apache-2.0 AND MIT` and points
here. Redistributing the files, or a source package that contains them,
requires retaining the MIT notice below.

### MIT license text

MIT License

Copyright (c) 2018 Anton Medvedev

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

No other file in this module transcribes third-party source or test
data beyond the Jexl material listed in the next section. Build-time
dependencies (for example `moonbitlang/core`) are resolved from the
MoonBit registry and are not redistributed in this module's source
package.

## TomFrost/Jexl

- Project: TomFrost/Jexl — <https://github.com/TomFrost/Jexl>
- Transcribed revision: tag `v2.3.0` (the version the stage-3
  differential harness in `tools/` runs against; see `tools/README.md`)
- License: MIT
- Copyright: Copyright (c) 2020 Tom Shawver

### Covered material

| mbel file | Upstream source | Ported content |
| --- | --- | --- |
| [`lexer/lexer.mbt`](lexer/lexer.mbt) | `lib/Lexer.js` | tokenization behavior: longest-first element matching, word-boundary rules for identifier-like symbols, numeric/identifier recognition, quote unescaping |
| [`grammar/grammar.mbt`](grammar/grammar.mbt) | `lib/grammar.js` | token-type classification and the element definitions (symbols, precedence, associativity) visible to the lexer and parser |
| [`parser/parser.mbt`](parser/parser.mbt) | `lib/parser/Parser.js`, `lib/parser/handlers.js`, `lib/parser/states.js` | the finite-state-machine parser and its cursor-based AST construction |
| [`evaluator/evaluator.mbt`](evaluator/evaluator.mbt) | `lib/evaluator/Evaluator.js`, `lib/evaluator/handlers.js` | tree-walking evaluation, operator/transform dispatch, eval-on-demand operators |
| [`evaluator/semantics.mbt`](evaluator/semantics.mbt) | `lib/grammar.js` eval functions | JavaScript value semantics: loose equality, truthiness, ToNumber/ToString coercions |
| [`engine_test/engine_test.mbt`](engine_test/engine_test.mbt) | `__tests__/lib/Jexl.test.js`, `__tests__/lib/Expression.test.js` | the Jest test cases, transcribed as blackbox tests |
| [`lexer_test/lexer_test.mbt`](lexer_test/lexer_test.mbt) | `__tests__/lib/Lexer.test.js` | the Jest lexer suite, transcribed verbatim as parity oracle |
| [`parser_test/parser_test.mbt`](parser_test/parser_test.mbt) | `__tests__/lib/parser/Parser.test.js` | the Jest parser suite; expected AST shapes mirror the JS `toEqual` expectations verbatim |
| [`evaluator_test/evaluator_test.mbt`](evaluator_test/evaluator_test.mbt) | `__tests__/lib/evaluator/Evaluator.test.js` | the Jest evaluator suite, transcribed as blackbox tests |

What is ported is the upstream behavior and the upstream test suites.
The MoonBit material around them — the hand-written scanner replacing
Jexl's regex split, the synchronous collapse of the Promise machinery,
the dual-engine harness — is original mbel work and remains under
Apache-2.0.

Because those files combine Apache-2.0 material with MIT material, each
carries `SPDX-License-Identifier: Apache-2.0 AND MIT` and
`SPDX-FileCopyrightText: 2020 Tom Shawver`, and points here.
Redistributing the files, or a source package that contains them,
requires retaining the MIT notice below.

The generated differential corpus (`tools/corpus.txt` and the test data
derived from it) is produced by running expressions through both
engines; it contains no transcribed Jexl source.

### MIT license text

MIT License

Copyright (c) 2020 Tom Shawver

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
