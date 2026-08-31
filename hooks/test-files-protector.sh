#!/usr/bin/env bash
# test-files-protector.sh
# PreToolUse hook: blocks Edit/Write operations against test files unless
# окно правки тестов открыто.
#
# КАК ДАЁТСЯ РАЗРЕШЕНИЕ. Файлом-маркером .gigacode/.cost/test-edit-allowed,
# который ставит и снимает scripts/test-edit-window.sh.
#
# Раньше разрешением служила переменная окружения PDLC_ALLOW_TEST_EDIT=1, а
# инструкция агенту (agents/test.md) предлагала выставить её командой `export`
# в Bash. Так это не работает никогда: каждый вызов Bash-инструмента — отдельный
# процесс, хук запускается рантаймом из своего, переменная между ними не
# передаётся. Значит test-агент не мог создать ни одного теста, и фаза Test —
# та самая, ради которой существует весь цикл — была заблокирована наглухо.
# Переменная сохранена как способ для CI (там окружение процесса задаёт
# оператор, и это действительно работает).
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

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

# Маркер разрешения лежит в корне проекта.
cd_harness_root

# Extract file_path from common shapes: Edit, Write, MultiEdit, NotebookEdit.
FILE_PATH="$(hook_field_any '.tool_input.file_path' '.tool_input.path' '.tool_input.notebook_path')"

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
  test_*.py|*/test_*.py)              is_test_file=1 ;;
esac

if [[ "$is_test_file" -eq 0 ]]; then
  exit 0
fi

# Test file detected. Разрешение — окно правки или переменная окружения (CI).
MARKER=".gigacode/.cost/test-edit-allowed"
if [[ -f "$MARKER" ]]; then
  echo "[test-files-protector] allowed edit to $FILE_PATH (окно правки тестов открыто: $(cat "$MARKER" 2>/dev/null))" >&2
  exit 0
fi
if [[ "${PDLC_ALLOW_TEST_EDIT:-0}" == "1" ]]; then
  echo "[test-files-protector] allowed edit to $FILE_PATH (PDLC_ALLOW_TEST_EDIT=1)" >&2
  exit 0
fi

# Block.
deny "Тесты — часть контракта, а не реализации. Правка $FILE_PATH молча изменила бы acceptance criteria. Если ты test-агент (или точно знаешь, что тест нужно обновить), открой окно: bash .gigacode/scripts/test-edit-window.sh open '<причина>' — и закрой его после фазы Test. §2.13 PDLC v3.5 (TDD discipline)." 
