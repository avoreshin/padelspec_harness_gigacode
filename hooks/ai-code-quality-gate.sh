#!/usr/bin/env bash
# PostToolUse hook для Write/Edit: запускает lint/typecheck на изменённом файле.
# Адаптируйте под свой стек.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

FILE_PATH="$(hook_field_any '.tool_input.file_path' '.tool_input.path')"

[[ -z "$FILE_PATH" ]] && exit 0
[[ ! -f "$FILE_PATH" ]] && exit 0

case "$FILE_PATH" in
  *.py)
    command -v ruff >/dev/null && ruff check "$FILE_PATH" >&2 || true
    ;;
  *.ts|*.tsx|*.js|*.jsx)
    command -v eslint >/dev/null && eslint "$FILE_PATH" >&2 || true
    ;;
  *.go)
    command -v gofmt >/dev/null && gofmt -l "$FILE_PATH" >&2 || true
    ;;
  *.rs)
    command -v cargo >/dev/null && cargo clippy --quiet >&2 || true
    ;;
esac

# Hook не блокирует — только сигнализирует. Блокировка происходит в Stop hook
# через проверку evidence bundle.
exit 0
