// Command parse_oracle parses a corpus of expr sources with the reference
// expr parser and prints the resulting AST in mbel's `dump()` convention.
//
// Usage (from tools/parse_oracle):
//
//	go run . ../../tools/parse_corpus.txt
//
// The module replaces github.com/expr-lang/expr with the local reference
// checkout (see go.mod); expr has no external dependencies, so this works
// offline. The output is frozen into
// expr_test/parse_want_data_test.mbt by tools/gen_parse_mbt.py and asserted
// against mbel's own dump by expr_test/parse_want_test.mbt — the same
// shape as the regex differential harness.
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/expr-lang/expr/ast"
	"github.com/expr-lang/expr/parser"
)

func opt(n ast.Node) string {
	if n == nil {
		return "?"
	}
	return d(n)
}

func d(n ast.Node) string {
	switch v := n.(type) {
	case *ast.NilNode:
		return "nil"
	case *ast.IdentifierNode:
		return "id:" + v.Value
	case *ast.IntegerNode:
		return "int:" + strconv.Itoa(v.Value)
	case *ast.FloatNode:
		return "float:" + strconv.FormatFloat(v.Value, 'f', -1, 64)
	case *ast.BoolNode:
		if v.Value {
			return "true"
		}
		return "false"
	case *ast.StringNode:
		return "str:" + v.Value
	case *ast.BytesNode:
		return "bytes"
	case *ast.UnaryNode:
		return "un(" + v.Operator + "," + d(v.Node) + ")"
	case *ast.BinaryNode:
		return "bin(" + v.Operator + "," + d(v.Left) + "," + d(v.Right) + ")"
	case *ast.MemberNode:
		// mbel spells a constant string property `member(base.prop)` and
		// any other property (an integer index, a computed key)
		// `index(base, prop)`.
		if s, ok := v.Property.(*ast.StringNode); ok {
			if v.Optional {
				return "member(" + d(v.Node) + "." + s.Value + "?)"
			}
			return "member(" + d(v.Node) + "." + s.Value + ")"
		}
		return "index(" + d(v.Node) + "," + d(v.Property) + ")"
	case *ast.SliceNode:
		return "slice(" + d(v.Node) + "," + opt(v.From) + "," + opt(v.To) + ")"
	case *ast.CallNode:
		out := "call(" + d(v.Callee)
		for _, a := range v.Arguments {
			out += "," + d(a)
		}
		return out + ")"
	case *ast.BuiltinNode:
		out := "call(id:" + v.Name
		for _, a := range v.Arguments {
			out += "," + d(a)
		}
		return out + ")"
	case *ast.PredicateNode:
		// mbel marks only brace-wrapped predicates with pred(); a bare
		// pointer argument is already unambiguous.
		if _, ok := v.Node.(*ast.PointerNode); ok {
			return d(v.Node)
		}
		return "pred(" + d(v.Node) + ")"
	case *ast.ConditionalNode:
		return "cond(" + d(v.Cond) + "," + opt(v.Exp1) + "," + opt(v.Exp2) + ")"
	case *ast.VariableDeclaratorNode:
		return "let(" + v.Name + "," + d(v.Value) + "," + d(v.Expr) + ")"
	case *ast.SequenceNode:
		parts := []string{}
		for _, x := range v.Nodes {
			parts = append(parts, d(x))
		}
		return "seq[" + strings.Join(parts, ";") + "]"
	case *ast.ArrayNode:
		parts := []string{}
		for _, x := range v.Nodes {
			parts = append(parts, d(x))
		}
		return "arr[" + strings.Join(parts, ",") + "]"
	case *ast.MapNode:
		parts := []string{}
		for _, x := range v.Pairs {
			parts = append(parts, d(x))
		}
		return "map{" + strings.Join(parts, ",") + "}"
	case *ast.PairNode:
		return d(v.Key) + ":" + d(v.Value)
	case *ast.PointerNode:
		// mbel writes pointers with their sigil: #, #index, #acc.
		if v.Name == "" {
			return "ptr:#"
		}
		return "ptr:#" + v.Name
	default:
		return "UNSUPPORTED"
	}
}

func unescape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 't':
			b.WriteByte('\t')
		case 'r':
			b.WriteByte('\r')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run . <corpus>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	idx := 0
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		tree, perr := parser.Parse(unescape(line))
		verdict := "ERR"
		if perr == nil {
			verdict = d(tree.Node)
		}
		// One row per line: keep literal newlines/tabs inside a dump
		// (a raw string may contain them) out of the transport format.
		verdict = strings.ReplaceAll(verdict, "\\", "\\\\")
		verdict = strings.ReplaceAll(verdict, "\n", "\\n")
		verdict = strings.ReplaceAll(verdict, "\t", "\\t")
		verdict = strings.ReplaceAll(verdict, "\r", "\\r")
		fmt.Fprintf(out, "%d\t%s\n", idx, verdict)
		idx++
	}
}
