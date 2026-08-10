#!/usr/bin/env bash
# PostToolUse hook для Write/Edit: запускает lint/typecheck на изменённом файле.
# Адаптируйте под свой стек.

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

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
