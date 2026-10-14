#!/usr/bin/env bash
# Toy test runner: executes every tests/*.test.sh and prints one summary line.
set -uo pipefail
pass=0; fail=0
for t in tests/*.test.sh; do
  [[ -f "$t" ]] || continue
  if bash "$t" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $t"; fi
done
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
