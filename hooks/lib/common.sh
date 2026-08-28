#!/usr/bin/env bash
# Shared helpers for GigaCode hooks.
# Source this file from any hook: source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

set -euo pipefail

# jq обязателен: hook_field/deny/emit_context держатся на нём. Без гейта хук
# падал бы с exit 127, а это для агента «хук не сработал» — политика
# переставала применяться молча. См. lib/require-jq.sh.
source "${BASH_SOURCE[0]%/*}/require-jq.sh" || exit 2

# Payload события (агент передаёт JSON хуку через stdin).
#
# Читается ЯВНО и ровно один раз — вызовом hook_read_payload первой строкой
# хука, которому payload нужен. Два способа, которые кажутся проще, не работают:
#
#   - лениво из hook_field: тот вызывается внутри $(...), то есть в подоболочке;
#     прочитанный там stdin в родителя не возвращается, кэш остаётся пустым, а
#     следующий вызов получает уже опустошённый поток. Хук видел бы ровно одно
#     поле payload, остальные — пустыми;
#   - автоматически при подключении, если `[[ ! -t 0 ]]`: тогда хук, вызванный
#     без данных на stdin, но с унаследованным открытым дескриптором (фоновый
#     запуск, CI, тестовый прогон), виснет в `cat` навсегда.
#
# Отсюда явный вызов: читает тот, кто payload действительно использует.
_HOOK_INPUT=""
_HOOK_INPUT_READ=0

# Отказ со статически зашитой причиной. Нужен там, где jq нельзя применить к
# самому событию (payload не разобрался) — экранировать через jq тогда нечего.
_hook_deny_static() {
  printf '{"decision":"deny","reason":"%s"}\n' "$1"
  printf '%s\n' "$1" >&2
  exit 2
}

# Payload обязан быть разбираемым JSON. Пустой stdin — законный случай (хук
# вызван без события, проверять нечего), а вот нечитаемый payload — нет: любой
# hook_field на нём валит jq с кодом 5, а из-за `set -o pipefail` + `set -e` хук
# умирает именно с 5. Блокировкой рантайм считает ТОЛЬКО exit 2 — то есть гейт
# молча переставал применяться. Это тот же режим отказа, ради которого написан
# lib/require-jq.sh, поэтому и разрешается он так же: fail-closed.
_hook_assert_json() {
  if [[ -z "$_HOOK_INPUT" ]]; then
    return 0
  fi
  if printf '%s' "$_HOOK_INPUT" | jq empty 2>/dev/null; then
    return 0
  fi
  _hook_deny_static "harness: событие хука пришло не как JSON, разобрать его нечем — вызов заблокирован (fail-closed, а не тихий пропуск: любой код возврата кроме 2 рантайм считает несработавшим хуком). Обычно это значит, что хук запущен вручную или из скрипта без корректного payload. Проверить окружение: команда /harness doctor (в GigaCode — /pdls:harness doctor)."
}

hook_read_payload() {
  if [[ "$_HOOK_INPUT_READ" -eq 0 ]]; then
    _HOOK_INPUT="$(cat)"
    _HOOK_INPUT_READ=1
    _hook_assert_json
  fi
}

hook_input() {
  printf '%s' "$_HOOK_INPUT"
}

# Заполнить кэш уже прочитанным payload'ом.
# Нужен хукам, которые читают stdin сами (INPUT=$(cat)): без этого hook_field
# внутри deny() попытается прочитать stdin второй раз, получит пустую строку и
# не сможет проставить hookEventName в решении.
hook_set_input() {
  _HOOK_INPUT="$1"
  _HOOK_INPUT_READ=1
  _hook_assert_json
}

# Extract a field from the hook input via jq.
# Usage: hook_field '.tool_input.command'
hook_field() {
  hook_input | jq -r "$1 // empty"
}

# Первое непустое значение из нескольких путей — слой совместимости между
# рантаймами. Одно и то же поле называется по-разному:
#   UserPromptSubmit  — .prompt (Qwen/GigaCode) vs .user_prompt (GigaCode)
#   имя события       — .hook_event_name везде, но старые сборки слали .event
# Usage: hook_field_any '.prompt' '.user_prompt' '.submitted_prompt'
hook_field_any() {
  local path value
  for path in "$@"; do
    value="$(hook_field "$path")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done
  return 0
}

# Корень проекта. Хуки хранят состояние по путям вида .gigacode/.cost и
# .gigacode/audit; агент запускает хук с cwd текущей рабочей директории, которая
# не обязана быть корнем репозитория (подкаталог, git worktree). Без резолва
# хук создаёт второй каталог состояния в подкаталоге и молча начинает читать
# пустой risk class — то есть работать как R1 при любом фактическом классе.
harness_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
  if [[ -n "$root" ]]; then printf '%s' "$root"; return 0; fi
  root="$(hook_field '.cwd')"
  if [[ -n "$root" && -d "$root" ]]; then printf '%s' "$root"; return 0; fi
  printf '%s' "$PWD"
}

cd_harness_root() {
  local root; root="$(harness_root)"
  [[ -n "$root" && -d "$root" ]] && cd "$root"
  return 0
}

# Отказать в выполнении вызова.
#
# Решение уходит в STDOUT: и GigaCode, и Qwen/GigaCode парсят как JSON
# только stdout, stderr у них — поток логов и текстовой причины отказа.
# Раньше вся обвязка печатала решение в stderr, поэтому структурированная часть
# не разбиралась вообще: работал лишь голый exit 2, а сам JSON показывался
# пользователю как сырой текст.
#
# Печатаем один объект, удовлетворяющий обоим контрактам сразу:
#   decision/reason                      — формат GigaCode / GigaCode
#   hookSpecificOutput.permissionDecision — актуальный формат GigaCode
# Значение "deny", а не "block": "block" ни один из рантаймов не распознаёт.
# Причина дублируется в stderr — это fallback-путь для exit 2.
deny() {
  local reason="$1"
  local event; event="$(hook_field '.hook_event_name')"
  [[ -n "$event" ]] || event="PreToolUse"
  jq -nc --arg r "$reason" --arg e "$event" '{
    decision: "deny",
    reason: $r,
    hookSpecificOutput: {
      hookEventName: $e,
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  printf '%s\n' "$reason" >&2
  exit 2
}

# Historical alias. Хуки писались под block(); поведение теперь общее — deny().
block() { deny "$1"; }

# Emit additional context for UserPromptSubmit (non-blocking).
# Usage: emit_context "warning or hint"
emit_context() {
  local msg="$1"
  local event; event="$(hook_field '.hook_event_name')"
  [[ -n "$event" ]] || event="UserPromptSubmit"
  jq -nc --arg m "$msg" --arg e "$event" \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
}

# Test whether a string matches any of the provided extended-regex patterns.
# Usage: matches_any "$value" "pattern1" "pattern2" ...
# Returns 0 on first match, 1 if no match.
matches_any() {
  local value="$1"; shift
  local pattern
  for pattern in "$@"; do
    if printf '%s' "$value" | grep -qE -- "$pattern"; then
      return 0
    fi
  done
  return 1
}
