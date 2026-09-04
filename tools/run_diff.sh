#!/bin/sh
# usage: ./tools/run_diff.sh <corpus-file>
cd "$(dirname "$0")/.."
c="${1:-tools/corpus.txt}"
node tools/jexl_driver.js "$c" > /tmp/jexl.out
moon run cmd/main -- "$(cat "$c")" 2>/dev/null > /tmp/mbel.out
diff /tmp/jexl.out /tmp/mbel.out && echo "=== IDENTICAL: $c ==="
