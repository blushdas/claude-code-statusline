#!/bin/bash
# tests/unit/token_display.sh — tests for token_display() and ctx_limit_k()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../lib/compute.sh"

describe "token_display — smart precision"
assert_eq "0.0k"   "$(token_display 0)"       "0 tokens → 0.0k"
assert_eq "0.1k"   "$(token_display 100)"      "100 → 0.1k"
assert_eq "1.0k"   "$(token_display 1000)"     "1000 → 1.0k"
assert_eq "1.2k"   "$(token_display 1200)"     "1200 → 1.2k"
assert_eq "9.9k"   "$(token_display 9900)"     "9900 → 9.9k"
assert_eq "10k"    "$(token_display 10000)"    "10000 → 10k (switches to integer)"
assert_eq "10k"    "$(token_display 10499)"    "10499 → 10k (floors)"
assert_eq "22k"    "$(token_display 22000)"    "22000 → 22k"
assert_eq "22k"    "$(token_display 22900)"    "22900 → 22k"
assert_eq "100k"   "$(token_display 100000)"   "100000 → 100k"
assert_eq "200k"   "$(token_display 200000)"   "200000 → 200k"

describe "ctx_limit_k — window size display"
assert_eq "200k"   "$(ctx_limit_k 200000)"     "200000 → 200k"
assert_eq "100k"   "$(ctx_limit_k 100000)"     "100000 → 100k"
assert_eq "8k"     "$(ctx_limit_k 8000)"       "8000 → 8k"
