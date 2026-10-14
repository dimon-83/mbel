// Command regex_oracle evaluates a corpus of RE2 pattern/subject pairs
// with Go's regexp package (RE2) and prints one verdict per case.
//
// Usage: go run tools/regex_oracle.go tools/regex_corpus.txt
//
// Output: "<index>\t<verdict>" per case, where verdict is "true",
// "false", or "error". Compile errors are reported as "error" without
// the message, because mbel's own regex dialect reports different text;
// only the match/no-match/error distinction is compared.
//
// This is the Go side of the `matches` differential harness. The MoonBit
// side is engine_test/regex_re2_test.mbt; the two are tied together by
// tools/gen_regex_mbt.py, which freezes the oracle's verdicts into
// engine_test/regex_re2_data_test.mbt.
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// unescape decodes the corpus escape convention: \n \t \r \f \v \\ \"
// become the corresponding character; every other backslash is literal.
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
		case 'f':
			b.WriteByte('\f')
		case 'v':
			b.WriteByte('\v')
		case '\\':
			b.WriteByte('\\')
		case '"':
			b.WriteByte('"')
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run tools/regex_oracle.go <corpus>")
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
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			fmt.Fprintf(os.Stderr, "case %d: not TAB separated\n", idx)
			os.Exit(1)
		}
		pat := unescape(parts[0])
		subj := unescape(parts[1])
		verdict := "error"
		if re, cerr := regexp.Compile(pat); cerr == nil {
			verdict = strconv.FormatBool(re.MatchString(subj))
		}
		fmt.Fprintf(out, "%d\t%s\n", idx, verdict)
		idx++
	}
	if err := sc.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
