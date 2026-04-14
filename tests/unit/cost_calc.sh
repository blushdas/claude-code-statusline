#!/bin/bash
# tests/unit/cost_calc.sh — tests for burn_rate() and cost_per_1k()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../lib/compute.sh"

describe "burn_rate — $/min"
# No cost or no duration → placeholder
assert_eq "-.--"   "$(burn_rate 0 0)"              "zero cost + zero duration → -.--"
assert_eq "-.--"   "$(burn_rate 0 60000)"           "zero cost → -.--"
assert_eq "-.--"   "$(burn_rate 0.5 0)"             "zero duration → -.--"

# $0.50 over 1 minute (60000ms) = $0.50/min
assert_eq "0.50"   "$(burn_rate 0.5 60000)"         "0.5 USD / 60s = 0.50/min"

# $1.00 over 2 minutes (120000ms) = $0.50/min
assert_eq "0.50"   "$(burn_rate 1.0 120000)"        "1.0 USD / 120s = 0.50/min"

# $0.18 over 30s (30000ms) = $0.36/min
assert_eq "0.36"   "$(burn_rate 0.18 30000)"        "0.18 USD / 30s = 0.36/min"

# $5.00 over 10 minutes = $0.50/min
assert_eq "0.50"   "$(burn_rate 5.0 600000)"        "5.0 USD / 600s = 0.50/min"

describe "cost_per_1k — $/1k tokens"
# No tokens or no cost → 0.0000
assert_eq "0.0000"   "$(cost_per_1k 0 0)"           "zero both → 0.0000"
assert_eq "0.0000"   "$(cost_per_1k 0 50000)"        "zero cost → 0.0000"
assert_eq "0.0000"   "$(cost_per_1k 0.5 0)"          "zero tokens → 0.0000"

# $0.50 for 100k tokens = $0.005/1k = $0.0050
assert_eq "0.0050"   "$(cost_per_1k 0.5 100000)"    "0.5 USD / 100k tokens = 0.0050/1k"

# $0.18 for 22900 tokens ≈ $0.0079/1k
assert_eq "0.0079"   "$(cost_per_1k 0.18 22900)"    "0.18 USD / 22.9k tokens ≈ 0.0079/1k"

# $1.00 for 10k tokens = $0.1000/1k
assert_eq "0.1000"   "$(cost_per_1k 1.0 10000)"     "1.0 USD / 10k tokens = 0.1000/1k"
