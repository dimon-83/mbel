module mbel/parse_oracle

go 1.18

require github.com/expr-lang/expr v0.0.0

// The reference checkout. Override with a local copy of expr-lang/expr:
//   go mod edit -replace github.com/expr-lang/expr=/path/to/expr
replace github.com/expr-lang/expr => ../../../expr
