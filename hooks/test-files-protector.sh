#!/usr/bin/env bash
# test-files-protector.sh
# PreToolUse hook: blocks Edit/Write operations against test files unless
# the caller explicitly opts in via PDLC_ALLOW_TEST_EDIT=1.
#
# Rationale: in TDD, tests are the executable acceptance criteria. The
# Coding Agent must NOT modify them to make implementation pass — that
# silently changes the contract. The Test Agent owns the tests and is
# the only role allowed to edit them, signalled by the env var.
#
# Detection of "test file":
#   - lives under test/ or tests/
#   - or matches *.test.* / *.spec.* / *_test.* / test_*.*
#   - or sits under __tests__/
#
# The hook reads tool input from stdin as JSON (GigaCode hook protocol).

set -euo pipefail

# Read the hook event payload from stdin.
PAYLOAD=$(cat)

# Extract file_path from common shapes: Edit, Write, MultiEdit, NotebookEdit.
FILE_PATH=$(echo "$PAYLOAD" | jq -r '
  .tool_input.file_path
  // .tool_input.path
  // .tool_input.notebook_path
  // empty
')

# Nothing to check.
if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

# Normalize: strip leading ./ for matching.
norm="${FILE_PATH#./}"

is_test_file=0
case "$norm" in
  test/*|tests/*|*/test/*|*/tests/*) is_test_file=1 ;;
  __tests__/*|*/__tests__/*)         is_test_file=1 ;;
  *.test.*|*.spec.*)                  is_test_file=1 ;;
  *_test.go|*_test.py|*_test.rs|*_test.ts|*_test.js) is_test_file=1 ;;
  test_*.py)                          is_test_file=1 ;;
esac

if [[ "$is_test_file" -eq 0 ]]; then
  exit 0
fi

# Test file detected. Check the opt-in.
if [[ "${PDLC_ALLOW_TEST_EDIT:-0}" == "1" ]]; then
  # Allowed (Test Agent or operator override). Audit it.
  echo "[test-files-protector] allowed edit to $FILE_PATH (PDLC_ALLOW_TEST_EDIT=1)" >&2
  exit 0
fi

# Block.
cat >&2 <<EOF
{"decision": "block", "reason": "Test files are part of the contract, not the implementation. Editing $FILE_PATH would change acceptance criteria silently. If you are the Test Agent (or know you must update the test), set PDLC_ALLOW_TEST_EDIT=1 for this session. §2.13 PDLC v3.5 (TDD discipline)."}
EOF
exit 2
