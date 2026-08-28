#!/usr/bin/env bash
# set-risk-class.sh — активирует risk-aware policy-хуки, записывая текущий
# risk class в состояние harness (.gigacode/.cost/current-risk-class).
#
# Зачем: destructive-command-blocker, cost-circuit-breaker,
# context-integrity-review и jsonl-audit-sink читают
# .gigacode/.cost/current-risk-class, но без писателя всегда откатываются на R1 —
# вся эскалация R2+/R3+ остаётся выключенной. Этот скрипт — единственный
# писатель, вызывается из /risk-classify и /sdd-new после подтверждения класса.
#
# Contract:
#   set-risk-class.sh R<N> [justification]
#     R<N>          — R0..R5
#     justification — свободный текст (опц.), уходит в аудиторский лог
#
# Формат файла: одна строка "R<N>" (хуки читают `cat | tr -d '[:space:]'`).
# Дополнительно ведём append-only лог .gigacode/.cost/risk-class.log
# (timestamp · класс · обоснование) — для audit-trail «кто/когда/почему».
#
# Здесь же обнуляется счётчик .gigacode/.cost/task-tokens: класс назначается на
# старте задачи, и бюджет из risk-ladder.yaml отсчитывается на задачу, а не на
# всё время жизни рабочей копии. Пишет счётчик hooks/token-usage-meter.sh.
#
# Exit codes: 0 — записано; 2 — usage / невалидный класс.

set -euo pipefail

usage() {
  echo "usage: set-risk-class.sh R<0-5> [justification]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage

CLASS="$1"
JUSTIFICATION="${2:-}"

if ! [[ "$CLASS" =~ ^R[0-5]$ ]]; then
  echo "error: risk class must match R0..R5, got: '$CLASS'" >&2
  usage
fi

# repo root — относительные .gigacode пути резолвятся независимо от cwd
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

COST_DIR=".gigacode/.cost"
mkdir -p "$COST_DIR"

RISK_FILE="$COST_DIR/current-risk-class"
LOG_FILE="$COST_DIR/risk-class.log"
TOKEN_FILE="$COST_DIR/task-tokens"

# Атомарная запись класса (только класс — формат, который читают хуки).
printf '%s\n' "$CLASS" > "$RISK_FILE"

# Новая задача — новый бюджет.
printf '0\n' > "$TOKEN_FILE"

# Аудиторский след (append-only).
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '%s\t%s\t%s\n' "$TS" "$CLASS" "$JUSTIFICATION" >> "$LOG_FILE"

echo "risk class set: $CLASS → $RISK_FILE (risk-aware hooks активированы; счётчик токенов обнулён)"
exit 0
