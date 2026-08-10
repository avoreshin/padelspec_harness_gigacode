#!/usr/bin/env bash
# UserPromptSubmit hook: мягкое напоминание о необходимости SDD для R2+.
# Не блокирует — только добавляет context в системный поток.

set -euo pipefail

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

# Эвристика: если в prompt упоминаются R3+ домены, напомнить о SDD
R3_KEYWORDS='auth|payment|password|credit card|PII|GDPR|migration|production'

if echo "$PROMPT" | grep -iqE "$R3_KEYWORDS"; then
  cat <<EOF
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "⚠️ Detected R3+ domain keywords. Ensure an approved SDD exists in docs/sdd/ before implementing. Risk class must be explicitly stated. See GIGACODE.md §3."}}
EOF
fi

exit 0
