#!/usr/bin/env bash
# UserPromptSubmit hook: мягкое напоминание о необходимости SDD для R2+.
# Не блокирует — только добавляет context в системный поток.
#
# ПЕРЕНОСИМОСТЬ. Текст промпта лежит в разных полях: `prompt` в GigaCode /
# GigaCode (плюс `submitted_prompt` с исходным вводом пользователя) и
# `user_prompt` в GigaCode. Читаем первое непустое — иначе в одной из сред
# хук молча работал бы на пустой строке и никогда не срабатывал.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

PROMPT="$(hook_field_any '.prompt' '.user_prompt' '.submitted_prompt')"
[ -z "$PROMPT" ] && exit 0

# Эвристика: если в prompt упоминаются R3+ домены, напомнить о SDD
R3_KEYWORDS='auth|payment|password|credit card|PII|GDPR|migration|production'

if printf '%s' "$PROMPT" | grep -iqE "$R3_KEYWORDS"; then
  emit_context "⚠️ Detected R3+ domain keywords. Ensure an approved SDD exists in docs/sdd/ before implementing. Risk class must be explicitly stated. See GIGACODE.md §3."
fi

exit 0
