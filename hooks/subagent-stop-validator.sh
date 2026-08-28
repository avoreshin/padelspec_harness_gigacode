#!/usr/bin/env bash
# subagent-stop-validator.sh
# SubagentStop hook: проверяет, что subagent выполнил свой mandate — вернул
# вывод в формате, который объявлен контрактом его профиля в .gigacode/agents/.
# Согласно §4.4 PDLC v3.5 (Policy Hook Framework) и §2.11 (Subagents as isolation).
#
# КОНТРАКТ СОБЫТИЯ. Полезная нагрузка SubagentStop содержит (одинаково в
# GigaCode и в GigaCode / GigaCode):
#   agent_id, agent_type, last_assistant_message, stop_hook_active,
#   agent_transcript_path (Qwen/GigaCode), permission_mode
# Вложенного объекта `subagent` с полями name/tools_used/output нет ни в одном
# рантайме. Прежняя версия читала именно его, поэтому AGENT_NAME всегда была
# пустой и хук выходил с exit 0 на первой же проверке: ни один контракт вывода
# не проверялся никогда. Здесь читается agent_type (с fallback на историческое
# .subagent.name, чтобы старые сборки не ломались).
#
# ЧЕГО ЗДЕСЬ БОЛЬШЕ НЕТ. Проверка tool scope («subagent использовал только
# инструменты из frontmatter `tools:`») убрана: списка фактически вызванных
# инструментов в событии нет, а восстанавливать его из транскрипта — гадание по
# недокументированному формату. Сам scope при этом никуда не делся — его
# применяет рантайм по полю `tools:` профиля, ещё до запуска субагента. Хук
# дублировал уже действующее ограничение, но делал это на несуществующих данных.
#
# Block → subagent run перезапускается parent'ом с уточнённым промптом.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

AGENT_NAME="$(hook_field_any '.agent_type' '.subagent.name')"
OUTPUT="$(hook_field_any '.last_assistant_message' '.subagent.output')"
STOP_HOOK_ACTIVE="$(hook_field '.stop_hook_active')"

if [[ -z "$AGENT_NAME" ]]; then
  # Не subagent или нет имени — пропускаем.
  exit 0
fi

# Уже идёт повтор, вызванный этим же хуком. Блокировать снова — значит зациклить
# субагента на одном и том же замечании: контракт вывода он либо исправил, либо
# не умеет исправить. Отдаём решение parent'у.
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  echo "[subagent-stop-validator] $AGENT_NAME: повторный проход, контракт не перепроверяется" >&2
  exit 0
fi

PROFILE=".gigacode/agents/$AGENT_NAME.md"
if [[ ! -f "$PROFILE" ]]; then
  echo "[subagent-stop-validator] Unknown subagent: $AGENT_NAME (no profile in .gigacode/agents/)" >&2
  exit 0
fi

# Вывод пуст (субагент прерван, либо рантайм не отдал текст) — судить не о чем.
if [[ -z "$OUTPUT" ]]; then
  echo "[subagent-stop-validator] $AGENT_NAME: пустой last_assistant_message, контракт не проверяется" >&2
  exit 0
fi

# === output contract checks по имени subagent ===
require_section() {
  local heading="$1" hint="$2"
  if ! printf '%s' "$OUTPUT" | grep -qE "^##[[:space:]]*$heading"; then
    deny "Вывод субагента '$AGENT_NAME' не содержит секцию '## $heading'. $hint Контракт: $PROFILE."
  fi
}

case "$AGENT_NAME" in
  explore)
    require_section "Scope"    "Explore возвращает structured context brief."
    require_section "Findings" "Explore возвращает structured context brief."
    ;;
  plan)
    require_section "Plan summary"         "См. контракт plan-агента."
    require_section "Risk class"           "См. контракт plan-агента."
    require_section "Implementation steps" "См. контракт plan-агента."
    ;;
  test)
    require_section "Tests added" "Test-агент отчитывается о добавленных тестах."
    # Должно быть подтверждение запуска
    if ! printf '%s' "$OUTPUT" | grep -qiE "(failed|passed)"; then
      deny "Вывод test-агента не содержит результата прогона (нет 'failed'/'passed'). TDD red требует доказательства, что тесты действительно запускались. Запусти прогон и вставь в отчёт строку с его результатом."
    fi
    ;;
  coding)
    require_section "Files changed" "Coding-агент перечисляет изменённые файлы."
    require_section "Self-check"    "Coding-агент отчитывается о самопроверке."
    # Defense: проверим, что coding не редактировал тесты.
    if printf '%s' "$OUTPUT" | grep -qE "(tests?/|_test\.|\.spec\.)"; then
      deny "Coding-агент, судя по отчёту, трогал тестовые файлы. Это нарушает §7 GIGACODE.md: тесты — acceptance criteria, менять их может только test-агент. Верни тестовые файлы в исходное состояние и передай нужные правки test-агенту; свои изменения ограничь кодом реализации."
    fi
    ;;
  review)
    require_section "Verdict" "Verdict должен быть APPROVE/REQUEST_CHANGES/BLOCK."
    VERDICT_LINE=$(printf '%s' "$OUTPUT" | awk '/^##[[:space:]]*Verdict/{flag=1; next} flag && NF{print; exit}')
    if ! printf '%s' "$VERDICT_LINE" | grep -qE "(APPROVE|REQUEST_CHANGES|BLOCK)"; then
      deny "Строка verdict у review-агента должна быть одной из APPROVE / REQUEST_CHANGES / BLOCK. Получено: $VERDICT_LINE. Добавь в отчёт строку 'verdict: <одно из трёх>' и повтори."
    fi
    ;;
  security)
    require_section "Verdict" "Verdict должен быть PASS/FAIL/NEEDS_HUMAN_REVIEW."
    VERDICT_LINE=$(printf '%s' "$OUTPUT" | awk '/^##[[:space:]]*Verdict/{flag=1; next} flag && NF{print; exit}')
    if ! printf '%s' "$VERDICT_LINE" | grep -qE "(PASS|FAIL|NEEDS_HUMAN_REVIEW)"; then
      deny "Строка verdict у security-агента должна быть одной из PASS / FAIL / NEEDS_HUMAN_REVIEW. Получено: $VERDICT_LINE. Добавь в отчёт строку 'verdict: <одно из трёх>' и повтори."
    fi
    ;;
esac

echo "[subagent-stop-validator] $AGENT_NAME passed contract check" >&2
exit 0
