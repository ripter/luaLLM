#!/usr/bin/env bash
set -euo pipefail

READY_RE="${READY_RE:-ready|listening|server started|model loaded}"
CMD=("$@")

t0_ns=$(date +%s%N)

# Start command, capture stdout+stderr line-by-line
# When we match READY_RE, print time and stop the process.
"${CMD[@]}" 2>&1 | awk -v re="$READY_RE" -v t0="$t0_ns" '
  BEGIN { matched=0 }
  {
    print $0 > "/dev/stderr"
    if (matched==0 && $0 ~ re) {
      matched=1
      "date +%s%N" | getline t1
      close("date +%s%N")
      ms = (t1 - t0) / 1000000
      printf("{\"startup_ms\": %.0f, \"ready_line\": \"%s\"}\n", ms, $0)
      fflush()
      exit 0
    }
  }
'

