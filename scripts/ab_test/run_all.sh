#!/usr/bin/env bash
# Run every A/B scenario; aggregate pass/fail. Green = all scenarios report 0 fail.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
total_p=0; total_f=0; failed=()
for t in scripts/ab_test/*.scenario.sh; do
  out="$(bash "$t" 2>&1)"
  line="$(printf '%s\n' "$out" | grep -E '^== .*: [0-9]+ pass, [0-9]+ fail ==' | tail -1)"
  p="$(sed -nE 's/^== .*: ([0-9]+) pass, [0-9]+ fail ==.*/\1/p' <<<"$line")"
  f="$(sed -nE 's/^== .*: [0-9]+ pass, ([0-9]+) fail ==.*/\1/p' <<<"$line")"
  p="${p:-0}"; f="${f:-0}"
  total_p=$((total_p + p)); total_f=$((total_f + f))
  [ "$f" != "0" ] && failed+=("$(basename "$t")")
  printf '%-46s %3s pass %3s fail\n' "$(basename "$t")" "$p" "$f"
done
echo "──────────────────────────────────────────────"
echo "TOTAL: ${total_p} pass, ${total_f} fail across $(ls scripts/ab_test/*.scenario.sh | wc -l | tr -d ' ') scenarios"
if [ "$total_f" != "0" ]; then
  echo "FAILING: ${failed[*]}"; echo "re-run a single scenario: bash scripts/ab_test/<name>.scenario.sh"
  exit 1
fi
echo "A/B harness: ALL GREEN"
