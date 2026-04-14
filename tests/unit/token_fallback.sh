#!/bin/bash
# tests/unit/token_fallback.sh — tests for token_or_fallback()
# This function fixes the post-/clear stale display bug:
# current_usage is 0 but used_percentage reflects system prompt load.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../lib/compute.sh"

describe "token_or_fallback — uses real tokens when available"
assert_eq "50000"   "$(token_or_fallback 50000 25 200000)"   "real tokens used over fallback"
assert_eq "22900"   "$(token_or_fallback 22900 11 200000)"   "real tokens used, ignores pct"
assert_eq "1"       "$(token_or_fallback 1 99 200000)"       "even 1 token skips fallback"

describe "token_or_fallback — fallback when current_usage is zero"
# 11% of 200000 = 22000 (matches /context output after /clear)
assert_eq "22000"   "$(token_or_fallback 0 11 200000)"   "11% of 200k → 22000"

# 50% of 200000 = 100000
assert_eq "100000"  "$(token_or_fallback 0 50 200000)"   "50% of 200k → 100000"

# 1% of 200000 = 2000
assert_eq "2000"    "$(token_or_fallback 0 1 200000)"    "1% of 200k → 2000"

# 95% of 200000 = 190000
assert_eq "190000"  "$(token_or_fallback 0 95 200000)"   "95% of 200k → 190000"

describe "token_or_fallback — both zero → zero (nothing to show)"
assert_eq "0"       "$(token_or_fallback 0 0 200000)"    "both zero → 0 (correct)"
