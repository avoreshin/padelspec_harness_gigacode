#!/usr/bin/env bash
# emit-phase-event.sh — единственный писатель событий `phase_transition` в audit-trail.
#
# Зачем: hook jsonl-audit-sink.sh пишет только tool-события (PostToolUse/…),
# а фазовые переходы не эмитит. Без этого скрипта /continue, /squash,
# workflow-state.sh и iteration cap в /implement читают события, которых
# никто не пишет. Phase Gate Protocol (SDD-20260522-phase-gate-protocol).
#
# Contract (вызывается из /plan, /test, /implement, /review, /evidence):
#   emit-phase-event.sh [--loop <dev|testing>] <task-id> <from> <to> <status> <iteration> [reason]
#
#   --loop       какой цикл: dev (по умолчанию) либо testing. Флаг опционален,
#                и без него скрипт ведёт себя ровно как раньше — включая состав
#                записи: поле `loop` добавляется только у testing. Иначе первая
#                же чужая задача перестала бы читаться старым workflow-state.
#   <task-id>    slug задачи (по нему workflow-state.sh собирает состояние);
#                для testing — ключ релиза, например ASFMSTD-8441
#   <from>       none + фазы своего цикла (none — первый переход)
#   <to>         фазы своего цикла + done
#   <status>     pass|fail|iterate|escalate
#   <iteration>  целое ≥ 1
#   [reason]     свободный текст (опц.) — объяснение перехода для audit-review
#
# Словари фаз:
#   dev      plan → test → implement → review → evidence → done
#   testing  profile → model → autotests → review → run → export → done
#
# Второй словарь не подмена первого, а другой процесс: в тестовом цикле
# acceptance criteria — это тест-модель, а не SDD, «тесты неприкосновенны»
# неприменимо (тесты и есть продукт), и вместо code-review идёт сверка
# сценариев с моделью. Натягивать его на имена dev-цикла значило бы писать в
# трейл неправду.
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
usage: emit-phase-event.sh [--loop <dev|testing>] <task-id> <from> <to> <status> <iteration> [reason]
  dev (по умолчанию)
    <from>   none|plan|test|implement|review|evidence
    <to>     plan|test|implement|review|evidence|done
  testing
    <from>   none|profile|model|autotests|review|run|export
    <to>     profile|model|autotests|review|run|export|done
  <status> pass|fail|iterate|escalate
  <iteration> integer >= 1
EOF
  exit 2
}

LOOP="dev"
if [ "${1:-}" = "--loop" ]; then
  [ "$#" -ge 2 ] || usage
  LOOP="$2"
  shift 2
fi
case "$LOOP" in
  dev|testing) ;;
  *) echo "error: invalid --loop: '$LOOP' (dev|testing)" >&2; usage ;;
esac

[ "$#" -ge 5 ] || usage

TASK_ID="$1"
FROM="$2"
TO="$3"
STATUS="$4"
ITERATION="$5"
REASON="${6:-}"

# --- validation ---
[ -n "$TASK_ID" ] || { echo "error: empty task-id" >&2; usage; }

if [ "$LOOP" = "testing" ]; then
  case "$FROM" in
    none|profile|model|autotests|review|run|export) ;;
    *) echo "error: invalid <from> for testing loop: '$FROM'" >&2; usage ;;
  esac
  case "$TO" in
    profile|model|autotests|review|run|export|done) ;;
    *) echo "error: invalid <to> for testing loop: '$TO'" >&2; usage ;;
  esac
else
  case "$FROM" in
    none|plan|test|implement|review|evidence) ;;
    *) echo "error: invalid <from>: '$FROM'" >&2; usage ;;
  esac
  case "$TO" in
    plan|test|implement|review|evidence|done) ;;
    *) echo "error: invalid <to>: '$TO'" >&2; usage ;;
  esac
fi

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
  --arg loop "$LOOP" \
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
  }
  # Поле добавляется только у testing: событие dev-цикла обязано остаться
  # побайтово тем же, иначе всё, что уже читает трейл, читает новый формат.
  + (if $loop == "dev" then {} else {loop: $loop} end)')

# Append-only. Никогда не перезаписываем.
printf '%s\n' "$RECORD" >> "$FILE"

echo "recorded: [$LOOP] $TASK_ID $FROM -> $TO ($STATUS, iter $ITERATION) into $FILE"
exit 0
