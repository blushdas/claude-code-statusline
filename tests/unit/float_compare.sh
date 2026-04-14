#!/bin/bash
# tests/unit/float_compare.sh — tests for _gt() and _ge()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers.sh"
source "$SCRIPT_DIR/../../lib/compute.sh"

describe "_gt (greater than)"
assert_true  '_gt 1.5 1.0'    "1.5 > 1.0"
assert_true  '_gt 0.001 0'    "0.001 > 0"
assert_true  '_gt 10 9.999'   "10 > 9.999"
assert_false '_gt 1.0 1.0'    "1.0 not > 1.0 (equal)"
assert_false '_gt 0.5 1.0'    "0.5 not > 1.0"
assert_false '_gt 0 0'        "0 not > 0"
assert_false '_gt 0 0.001'    "0 not > 0.001"

describe "_ge (greater than or equal)"
assert_true  '_ge 1.0 1.0'    "1.0 >= 1.0 (equal)"
assert_true  '_ge 1.1 1.0'    "1.1 >= 1.0"
assert_true  '_ge 5 5'        "5 >= 5"
assert_true  '_ge 5 3'        "5 >= 3"
assert_true  '_ge 0 0'        "0 >= 0"
assert_false '_ge 0.5 1.0'    "0.5 not >= 1.0"
assert_false '_ge 2.99 3'     "2.99 not >= 3"

describe "_gt/_ge with cost thresholds"
assert_true  '_ge 5 5'        "BURN threshold: exactly 5 triggers"
assert_true  '_ge 5.01 5'     "BURN threshold: 5.01 triggers"
assert_false '_ge 4.99 5'     "BURN threshold: 4.99 does not trigger"
assert_true  '_ge 3 3'        "WARN threshold: exactly 3 triggers"
assert_false '_ge 2.99 3'     "WARN threshold: 2.99 does not trigger"
