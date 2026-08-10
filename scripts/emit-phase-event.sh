#!/usr/bin/env bash
# emit-phase-event.sh — единственный писатель событий `phase_transition` в audit-trail.
#
# Зачем: hook jsonl-audit-sink.sh пишет только tool-события (PostToolUse/…),
# а фазовые переходы не эмитит. Без этого скрипта /continue, /squash,
# workflow-state.sh и iteration cap в /implement читают события, которых
# никто не пишет. Phase Gate Protocol (SDD-20260522-phase-gate-protocol).
#
# Contract (вызывается из /plan, /test, /implement, /review, /evidence):
#   emit-phase-event.sh <task-id> <from> <to> <status> <iteration> [reason]
#
#   <task-id>    slug SDD-задачи (по нему workflow-state.sh собирает состояние)
#   <from>       none|plan|test|implement|review|evidence  (none — первый переход)
#   <to>         plan|test|implement|review|evidence|done
#   <status>     pass|fail|iterate|escalate
#   <iteration>  целое ≥ 1
#   [reason]     свободный текст (опц.) — объяснение перехода для audit-review
#
# Пишет ОДНУ compact-JSON строку в .gigacode/audit/<YYYY-MM-DD>.jsonl.
# Формат согласован с jsonl-audit-sink (timestamp/event/risk_class) и со
# схемой audit-event.schema.json; compact-вывод (без пробелов) обязателен —
# workflow-state.sh матчит подстроки "event":"phase_transition" и "task_id":"…".
#
# Exit codes: 0 — записано; 2 — usage / невалидный аргумент.

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: emit-phase-event.sh <task-id> <from> <to> <status> <iteration> [reason]
  <from>   none|plan|test|implement|review|evidence
  <to>     plan|test|implement|review|evidence|done
  <status> pass|fail|iterate|escalate
  <iteration> integer >= 1
EOF
  exit 2
}

[ "$#" -ge 5 ] || usage

TASK_ID="$1"
FROM="$2"
TO="$3"
STATUS="$4"
ITERATION="$5"
REASON="${6:-}"

# --- validation ---
[ -n "$TASK_ID" ] || { echo "error: empty task-id" >&2; usage; }

case "$FROM" in
  none|plan|test|implement|review|evidence) ;;
  *) echo "error: invalid <from>: '$FROM'" >&2; usage ;;
esac

case "$TO" in
  plan|test|implement|review|evidence|done) ;;
  *) echo "error: invalid <to>: '$TO'" >&2; usage ;;
esac

case "$STATUS" in
  pass|fail|iterate|escalate) ;;
  *) echo "error: invalid <status>: '$STATUS'" >&2; usage ;;
esac

case "$ITERATION" in
  ''|*[!0-9]*) echo "error: <iteration> must be a positive integer: '$ITERATION'" >&2; usage ;;
esac
[ "$ITERATION" -ge 1 ] || { echo "error: <iteration> must be >= 1" >&2; usage; }

command -v jq >/dev/null 2>&1 || { echo "error: jq required" >&2; exit 2; }

# --- repo root (relative .gigacode paths resolve regardless of cwd) ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

AUDIT_DIR=".gigacode/audit"
mkdir -p "$AUDIT_DIR"

DATE=$(date -u +"%Y-%m-%d")
# Секундная точность — валидный RFC3339 и на GNU, и на BSD date (macOS не умеет %N).
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
FILE="$AUDIT_DIR/$DATE.jsonl"

# --- current risk class (default R1, как в jsonl-audit-sink) ---
RISK_CLASS="R1"
if [ -f ".gigacode/.cost/current-risk-class" ]; then
  RISK_CLASS=$(tr -d '[:space:]' < .gigacode/.cost/current-risk-class 2>/dev/null || echo "R1")
fi
[[ "$RISK_CLASS" =~ ^R[0-5]$ ]] || RISK_CLASS="R1"

# --- build compact record (jq -c → без пробелов, что нужно workflow-state.sh) ---
RECORD=$(jq -nc \
  --arg ts "$TS" \
  --arg task "$TASK_ID" \
  --arg from "$FROM" \
  --arg to "$TO" \
  --arg status "$STATUS" \
  --argjson iter "$ITERATION" \
  --arg reason "$REASON" \
  --arg rc "$RISK_CLASS" \
  '{
    timestamp:  $ts,
    event:      "phase_transition",
    task_id:    $task,
    from:       $from,
    to:         $to,
    status:     $status,
    iteration:  $iter,
    reason:     $reason,
    risk_class: $rc
  }')

# Append-only. Никогда не перезаписываем.
printf '%s\n' "$RECORD" >> "$FILE"

echo "recorded: $TASK_ID $FROM -> $TO ($STATUS, iter $ITERATION) into $FILE"
exit 0
