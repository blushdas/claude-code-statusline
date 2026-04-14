#!/bin/bash
# tests/run.sh — master test runner for claude-code-statusline
# Usage: bash tests/run.sh
# Exit code: 0 if all pass, 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared counters — exported so sourced files accumulate into same total
PASS=0
FAIL=0

source "$SCRIPT_DIR/helpers.sh"

printf "\033[1mstatusline unit tests\033[0m\n"
printf "lib: %s\n" "$SCRIPT_DIR/../lib/compute.sh"

# Run each unit test suite
for suite in "$SCRIPT_DIR/unit/"*.sh; do
  # Each suite sources helpers.sh and lib/compute.sh internally.
  # We source them here so PASS/FAIL counters accumulate in this shell.
  source "$suite"
done

# Summary
printf "\n────────────────────────────\n"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf "\033[32m✓ All %d tests passed\033[0m\n" "$TOTAL"
  exit 0
else
  printf "\033[31m✗ %d/%d tests failed\033[0m\n" "$FAIL" "$TOTAL"
  exit 1
fi
