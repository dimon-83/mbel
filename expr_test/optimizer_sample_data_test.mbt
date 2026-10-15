// AUTO-GENERATED from the reference expr optimizer test table — do not edit.
// Regenerate with tools/gen_optimizer_sample.py.
//
// expr's TestOptimize table (optimizer/optimizer_test.go): each input
// with the value expr produces *with* its optimizer passes enabled.
// expr_test/optimizer_sample_test.mbt evaluates the same inputs without
// those passes and asserts the same result, which is the property that
// matters given the passes are documented as not portable.

///|
let optimizer_sample_cases : Array[(String, String)] = [
  ("1 + 2", "3"),
  ("sum([])", "0"),
  ("sum([a])", "1"),
  ("sum([a, b])", "3"),
  ("sum([a, b, c])", "6"),
  ("sum([a, b, c, 4])", "10"),
  ("sum(1..10, # * 1000)", "55000"),
  ("sum(map(1..10, # * 1000), # / 1000)", "55"),
  ("all(1..3, {# > 0}) && all(1..3, {# < 4})", "true"),
  ("all(1..3, {# > 2}) && all(1..3, {# < 4})", "false"),
  ("all(1..3, {# > 0}) && all(1..3, {# < 2})", "false"),
  ("all(1..3, {# > 2}) && all(1..3, {# < 2})", "false"),
  ("all(1..3, {# > 0}) || all(1..3, {# < 4})", "true"),
  ("all(1..3, {# > 0}) || all(1..3, {# != 2})", "true"),
  ("all(1..3, {# != 3}) || all(1..3, {# < 4})", "true"),
  ("all(1..3, {# != 3}) || all(1..3, {# != 2})", "false"),
  ("none(1..3, {# == 0})", "true"),
  ("none(1..3, {# == 0}) && none(1..3, {# == 4})", "true"),
  ("none(1..3, {# == 0}) && none(1..3, {# == 3})", "false"),
  ("none(1..3, {# == 1}) && none(1..3, {# == 4})", "false"),
  ("none(1..3, {# == 1}) && none(1..3, {# == 3})", "false"),
  ("none(1..3, {# == 0}) || none(1..3, {# == 4})", "true"),
  ("none(1..3, {# == 0}) || none(1..3, {# == 3})", "true"),
  ("none(1..3, {# == 1}) || none(1..3, {# == 4})", "true"),
  ("none(1..3, {# == 1}) || none(1..3, {# == 3})", "false"),
  ("any([1, 1, 0, 1], {# == 0})", "true"),
  ("any(1..3, {# == 1}) && any(1..3, {# == 2})", "true"),
  ("any(1..3, {# == 0}) && any(1..3, {# == 2})", "false"),
  ("any(1..3, {# == 1}) && any(1..3, {# == 4})", "false"),
  ("any(1..3, {# == 0}) && any(1..3, {# == 4})", "false"),
  ("any(1..3, {# == 1}) || any(1..3, {# == 2})", "true"),
  ("any(1..3, {# == 0}) || any(1..3, {# == 2})", "true"),
  ("any(1..3, {# == 1}) || any(1..3, {# == 4})", "true"),
  ("any(1..3, {# == 0}) || any(1..3, {# == 4})", "false"),
  ("one([1, 1, 0, 1], {# == 0}) and not one([1, 0, 0, 1], {# == 0})", "true"),
  ("one(1..3, {# == 1}) and one(1..3, {# == 2})", "true"),
  ("one(1..3, {# == 1 || # == 2}) and one(1..3, {# == 2})", "false"),
  ("one(1..3, {# == 1}) and one(1..3, {# == 2 || # == 3})", "false"),
  ("one(1..3, {# == 1 || # == 2}) and one(1..3, {# == 2 || # == 3})", "false"),
  ("one(1..3, {# == 1}) or one(1..3, {# == 2})", "true"),
  ("one(1..3, {# == 1 || # == 2}) or one(1..3, {# == 2})", "true"),
  ("one(1..3, {# == 1}) or one(1..3, {# == 2 || # == 3})", "true"),
  ("one(1..3, {# == 1 || # == 2}) or one(1..3, {# == 2 || # == 3})", "false"),
]
