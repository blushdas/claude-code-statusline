#!/bin/bash
# tests/unit/rtk_format.sh — tests for rtk_format()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../lib/compute.sh"

describe "rtk_format — token savings display"
# Sub-10k range: one decimal place
assert_eq "1.0k"    "$(rtk_format 1000)"     "1000 → 1.0k"
assert_eq "1.2k"    "$(rtk_format 1200)"     "1200 → 1.2k"
assert_eq "9.9k"    "$(rtk_format 9900)"     "9900 → 9.9k"

# 10k-999k range: integer k
assert_eq "10k"     "$(rtk_format 10000)"    "10000 → 10k"
assert_eq "203k"    "$(rtk_format 203000)"   "203000 → 203k"
assert_eq "999k"    "$(rtk_format 999000)"   "999000 → 999k"

# 1M+ range: one decimal M
assert_eq "1.0M"    "$(rtk_format 1000000)"  "1000000 → 1.0M"
assert_eq "1.5M"    "$(rtk_format 1500000)"  "1500000 → 1.5M"
assert_eq "2.3M"    "$(rtk_format 2300000)"  "2300000 → 2.3M"

describe "rtk_dollars — token savings to dollar cost"
assert_eq '$0.000'  "$(rtk_dollars 0)"        "0 tokens → \$0.000"
assert_eq '$0.003'  "$(rtk_dollars 1000)"     "1k tokens → \$0.003"
assert_eq '$3.00'   "$(rtk_dollars 1000000)"  "1M tokens → \$3.00"
assert_eq '$11.40'  "$(rtk_dollars 3800000)"  "3.8M tokens → \$11.40"
assert_eq '$0.01'   "$(rtk_dollars 3334)"     "3334 tokens → \$0.01"
