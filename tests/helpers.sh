#!/bin/bash
# tests/helpers.sh — shared assert helpers for statusline unit tests

# Counters (accumulated across sourced test files via run.sh)
PASS=${PASS:-0}
FAIL=${FAIL:-0}

# Print a test suite header
describe() {
  printf "\n\033[1m%s\033[0m\n" "$1"
}

# assert_eq <expected> <actual> [desc]
assert_eq() {
  local expected="$1" actual="$2" desc="${3:-assertion}"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32m✓\033[0m %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$desc"
    printf "    expected: \033[33m%s\033[0m\n" "$expected"
    printf "    actual:   \033[31m%s\033[0m\n" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

# assert_true <exit-code-zero command> [desc]
assert_true() {
  local desc="${2:-assertion}"
  if eval "$1"; then
    printf "  \033[32m✓\033[0m %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$desc"
    FAIL=$((FAIL + 1))
  fi
}

# assert_false <non-zero command> [desc]
assert_false() {
  local desc="${2:-assertion}"
  if ! eval "$1"; then
    printf "  \033[32m✓\033[0m %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  \033[31m✗\033[0m %s\n" "$desc"
    FAIL=$((FAIL + 1))
  fi
}
