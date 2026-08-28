#!/usr/bin/env bash
# session-status.sh — SessionStart hook: одна строка состояния обвязки.
#
# ЗАЧЕМ. Состояние, от которого зависит поведение всех остальных хуков, до сих
# пор нельзя было увидеть, не выполнив три отдельные команды. Хуже того, два из
# четырёх полей меняют исход молча:
#   - при отсутствии jq одиннадцать хуков уходят в fail-closed (lib/require-jq.sh),
#     и первая же блокировка выглядит как поломка обвязки, а не как отсутствие
#     зависимости;
#   - забытое открытым окно правки тестов снимает test-files-protector.sh на всю
#     сессию, то есть отключает главный гейт TDD.
# Строка печатается в начале сессии, когда цена реакции ещё нулевая.
#
# НЕ подключает lib/common.sh и, соответственно, lib/require-jq.sh: гейт при
# отсутствии jq завершается с exit 2, а этот хук обязан отработать именно в том
# случае, о котором сообщает. jq используется только для необязательного
# additionalContext и вызывается через проверку наличия.
#
# Никогда не блокирует: SessionStart не входит в список блокирующих событий ни в
# GigaCode, ни в GigaCode / GigaCode (см. gigacode-md-placeholders.sh), поэтому
# ненулевой код здесь означал бы только шум в hook-докторе.

set -u

if _root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_root" ]; then
  cd "$_root" || exit 0
fi

COST_DIR=".gigacode/.cost"

# Версия. В самой обвязке лежит в VERSION, в проекте после /init-project —
# в .gigacode/.harness-version (VERSION в целевой репозиторий не копируется).
VERSION="н/д"
for _vf in ".gigacode/.harness-version" "VERSION"; do
  if [ -f "$_vf" ]; then
    VERSION="$(tr -d '[:space:]' < "$_vf" 2>/dev/null || echo "н/д")"
    [ -n "$VERSION" ] || VERSION="н/д"
    break
  fi
done

# Класс риска. Тот же дефолт и та же санитизация, что у cost-circuit-breaker.sh:
# рассинхрон между тем, что показывает статус, и тем, по чему гейтит бюджет,
# был бы хуже отсутствия строки.
RISK="R1"
if [ -f "$COST_DIR/current-risk-class" ]; then
  RISK="$(tr -d '[:space:]' < "$COST_DIR/current-risk-class" 2>/dev/null || echo "R1")"
fi
case "$RISK" in
  R0|R1|R2|R3|R4|R5) ;;
  *) RISK="R1" ;;
esac

# Окно правки тестов — файл-маркер, тот же, что читает test-files-protector.sh.
if [ -f "$COST_DIR/test-edit-allowed" ]; then
  WINDOW="открыто"
else
  WINDOW="закрыто"
fi

if command -v jq >/dev/null 2>&1; then
  JQ="есть"
else
  JQ="НЕ НАЙДЕН"
fi

LINE="harness $VERSION · risk $RISK · окно правки тестов: $WINDOW · jq: $JQ"

{
  echo "$LINE"
  if [ "$JQ" = "НЕ НАЙДЕН" ]; then
    echo "  ⚠ без jq одиннадцать хуков блокируют вызовы вместо применения политики (fail-closed). Установи: brew install jq | apt-get install jq | winget install jqlang.jq"
  fi
  if [ "$WINDOW" = "открыто" ]; then
    echo "  ⚠ окно правки тестов открыто — пока оно открыто, правки в тестах не блокируются. Закрыть: bash .gigacode/scripts/test-edit-window.sh close"
  fi
} >&2

# additionalContext — чтобы состояние видел не только человек в логе, но и
# модель. Требует jq для экранирования; в единственном случае, когда jq нет,
# сообщение об этом уже ушло в stderr.
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg m "$LINE" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
fi

exit 0
