#!/usr/bin/env bash
# PreToolUse hook для Write/Edit: проверяет, что в записываемом контенте нет утечки PII / secrets.
# Простая эвристика — для production используйте детальные сканеры (gitleaks, trufflehog).

set -euo pipefail

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // ""')

# Проверка на запись в защищённые пути
PROTECTED_PATHS=(
  '\.env$'
  '\.env\.'
  '/credentials'
  '/secrets/'
  '\.pem$'
  '\.key$'
)
for path_pattern in "${PROTECTED_PATHS[@]}"; do
  if echo "$FILE_PATH" | grep -qE "$path_pattern"; then
    echo "{\"decision\": \"block\", \"reason\": \"Writing to protected path: $FILE_PATH. Secrets must not be committed to repo.\"}" >&2
    exit 2
  fi
done

# Эвристика по содержимому
SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'                           # AWS Access Key
  'sk-[a-zA-Z0-9]{40,}'                        # OpenAI / Anthropic-like secret keys
  '-----BEGIN (RSA |OPENSSH )?PRIVATE KEY-----'
  'ghp_[a-zA-Z0-9]{36}'                        # GitHub Personal Access Token
  'xox[baprs]-[0-9a-zA-Z-]{10,}'               # Slack tokens
)
for pattern in "${SECRET_PATTERNS[@]}"; do
  if echo "$CONTENT" | grep -qE "$pattern"; then
    echo "{\"decision\": \"block\", \"reason\": \"Detected secret-like pattern in content. Do not commit secrets.\"}" >&2
    exit 2
  fi
done

exit 0
