#!/usr/bin/env bash
# PreToolUse hook для Write/Edit/MultiEdit/NotebookEdit: проверяет, что в
# записываемом контенте нет утечки PII / secrets.
#
# ГРАНИЦА ПРИМЕНИМОСТИ. Это эвристика на нескольких шаблонах, а не сканер
# секретов. Она ловит характерный вид известных ключей в открытом виде и не
# ловит ничего собранного из частей, закодированного или просто не попавшего в
# список. Для реального покрытия ставьте gitleaks / trufflehog в pre-commit и
# в CI; этот хук — быстрая проверка на границе записи, не замена им.
#
# v2: закрыты два провала, найденные прогоном по живому хуку.
#   - MultiEdit проходил насквозь. Матчер в settings.json включает MultiEdit,
#     но контент читался только из .content / .new_string, а у MultiEdit правки
#     лежат в .edits[].new_string — секрет в такой записи не проверялся вообще.
#   - Шаблон приватного ключа никогда не срабатывал: он начинается с дефиса, и
#     grep разбирал '-----BEGIN …' как свои опции, печатая "unrecognized
#     option" и молча пропуская проверку. Лечится '--' перед шаблоном.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

FILE_PATH="$(hook_field_any '.tool_input.file_path' '.tool_input.path' '.tool_input.notebook_path')"

# Весь текст, который вызов собирается записать. Собираем из всех форм сразу:
#   Write        → .content
#   Edit         → .new_string
#   MultiEdit    → .edits[].new_string
#   NotebookEdit → .new_source
CONTENT="$(hook_input | jq -r '
  [ .tool_input.content?
  , .tool_input.new_string?
  , .tool_input.new_source?
  , (.tool_input.edits? // [] | .[]? | .new_string?)
  ] | map(select(. != null)) | join("\n")
' 2>/dev/null || true)"

# Проверка на запись в защищённые пути
PROTECTED_PATHS=(
  '\.env$'
  '\.env\.'
  '/credentials'
  '/secrets/'
  '\.pem$'
  '\.key$'
  '/\.ssh/'
  'id_rsa'
)
for path_pattern in "${PROTECTED_PATHS[@]}"; do
  if printf '%s' "$FILE_PATH" | grep -qE -- "$path_pattern"; then
    deny "Writing to protected path: $FILE_PATH. Secrets must not be committed to repo."
  fi
done

[ -z "$CONTENT" ] && exit 0

# Эвристика по содержимому.
# Каждый шаблон сопоставляется через `grep -qE --`: без разделителя шаблоны,
# начинающиеся с дефиса, разбираются как опции grep и проверка тихо выпадает.
SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'                           # AWS Access Key
  'ASIA[0-9A-Z]{16}'                           # AWS temporary key
  'sk-[a-zA-Z0-9]{40,}'                        # OpenAI-подобные ключи
  'sk-ant-[a-zA-Z0-9_-]{20,}'                  # Anthropic API key
  '-----BEGIN (RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY-----'
  'ghp_[a-zA-Z0-9]{36}'                        # GitHub Personal Access Token
  'gho_[a-zA-Z0-9]{36}'                        # GitHub OAuth token
  'github_pat_[a-zA-Z0-9_]{22,}'               # GitHub fine-grained PAT
  'glpat-[a-zA-Z0-9_-]{20,}'                   # GitLab PAT
  'xox[baprs]-[0-9a-zA-Z-]{10,}'               # Slack tokens
  'AIza[0-9A-Za-z_-]{35}'                      # Google API key
)
for pattern in "${SECRET_PATTERNS[@]}"; do
  if printf '%s' "$CONTENT" | grep -qE -- "$pattern"; then
    deny "Detected secret-like pattern in content ($FILE_PATH). Do not commit secrets."
  fi
done

exit 0
