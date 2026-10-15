// Command time_oracle evaluates a corpus of date strings the way expr's
// `date()` builtin does (builtin/builtin.go: the 7-layout scan with
// time.Parse) and prints the result as int64 UnixNano, or ERR.
//
// expr returns Go time.Time values; mbel represents an instant as int64
// nanoseconds since the Unix epoch, so UnixNano is the comparable form.
// Rows are frozen into expr_test/time_want_data_test.mbt.
//
// Usage (from tools/time_oracle):
//
//	go run . ../../tools/time_corpus.txt
package main

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// expr's default layout list, in order.
var layouts = []string{
	"2006-01-02",
	"15:04:05",
	"2006-01-02 15:04:05",
	time.RFC3339,
	time.RFC822,
	time.RFC850,
	time.RFC1123,
}

// dateNoTZ mirrors expr's date(string) branch.
func dateNoTZ(date string) (any, error) {
	for _, layout := range layouts {
		if t, err := time.Parse(layout, date); err == nil {
			return t, nil
		}
	}
	return nil, fmt.Errorf("invalid date %s", date)
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
		v, err := dateNoTZ(unescape(line))
		verdict := "ERR"
		if err == nil {
			verdict = strconv.FormatInt(v.(time.Time).UnixNano(), 10)
		}
		fmt.Fprintf(out, "%d\t%s\n", idx, verdict)
		idx++
	}
}
