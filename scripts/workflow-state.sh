#!/usr/bin/env bash
# workflow-state.sh — выдаёт текущее состояние задачи по audit-trail.
#
# Source SDD: docs/sdd/20260523-workflow-orchestration.md (R1, approved 2026-05-23),
# AC-1 — SDD живёт в рабочем репозитории pdlc-harness-work.
#
# Source of truth: .gigacode/audit/*.jsonl, события `phase_transition`
# (Phase Gate Protocol, SDD-20260522-phase-gate-protocol).
#
# Usage:
#   scripts/workflow-state.sh <task-id>            # default --json
#   scripts/workflow-state.sh <task-id> --json
#   scripts/workflow-state.sh <task-id> --text     # human-readable
#
# Exit codes:
#   0 — task found, state printed
#   1 — task_id не найден в audit
#   2 — usage / internal error

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

AUDIT_GLOB=".gigacode/audit/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl"
TASK_ID=""
FORMAT="json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    -h|--help)
      cat <<'EOF'
usage: workflow-state.sh <task-id> [--json | --text]

Parses .gigacode/audit/*.jsonl for `phase_transition` events matching <task-id>
and reports current workflow state.

Output (--json, default):
  {"task_id":"...","current_phase":"...","last_status":"...","iteration":N,
   "started_at":"...","last_updated":"...","next_recommended_command":"...",
   "total_events":N}

Output (--text): same data as human-readable summary.

Exit codes:
  0 — task found
  1 — task_id not found in audit
  2 — usage / internal error
EOF
      exit 0 ;;
    --*) echo "error: unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$TASK_ID" ]; then
        TASK_ID="$1"; shift
      else
        echo "error: unexpected arg: $1" >&2; exit 2
      fi
      ;;
  esac
done

if [ -z "$TASK_ID" ]; then
  echo "error: task-id required (e.g. SDD-20260522-phase-gate-protocol)" >&2
  echo "usage: workflow-state.sh <task-id> [--json | --text]" >&2
  exit 2
fi

# Collect phase_transition events for this task across all audit files
EVENTS=()
START=""
LAST_EVENT=""
TOTAL=0

if ! ls $AUDIT_GLOB >/dev/null 2>&1; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"task_id":"%s","status":"no_audit","total_events":0}\n' "$TASK_ID"
  else
    printf 'task: %s — no audit files yet\n' "$TASK_ID"
  fi
  exit 1
fi

for f in $AUDIT_GLOB; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Only phase_transition events with matching task_id
    case "$line" in
      *'"event":"phase_transition"'*) ;;
      *) continue ;;
    esac
    case "$line" in
      *"\"task_id\":\"$TASK_ID\""*) ;;
      *) continue ;;
    esac
    TOTAL=$((TOTAL+1))
    [ -z "$START" ] && START="$line"
    LAST_EVENT="$line"
  done < "$f"
done

if [ "$TOTAL" -eq 0 ]; then
  if [ "$FORMAT" = "json" ]; then
    printf '{"task_id":"%s","status":"not_found","total_events":0}\n' "$TASK_ID"
  else
    printf 'task: %s — no phase_transition events found\n' "$TASK_ID"
    printf 'hint: запусти /sdd-new <slug> чтобы создать SDD, или /workflow <slug> для full orchestration\n'
  fi
  exit 1
fi

# Extract fields from LAST_EVENT
extract() {
  # $1 = JSON line, $2 = key (e.g. "to" or "iteration")
  # Bash-only extraction (no jq required; tolerant of nested payload):
  local line="$1"; local key="$2"
  # Numeric value
  local n; n=$(printf '%s' "$line" | sed -nE "s/.*\"$key\":([0-9]+).*/\1/p" | head -1)
  if [ -n "$n" ]; then printf '%s' "$n"; return; fi
  # String value
  local s; s=$(printf '%s' "$line" | sed -nE "s/.*\"$key\":\"([^\"]+)\".*/\1/p" | head -1)
  printf '%s' "$s"
}

# Phase fields: phase_transition event payload has {from, to, reason, iteration}
CURRENT_PHASE=$(extract "$LAST_EVENT" "to")
LAST_STATUS=$(extract "$LAST_EVENT" "status")
[ -z "$LAST_STATUS" ] && LAST_STATUS="$(extract "$LAST_EVENT" "to_status")"
[ -z "$LAST_STATUS" ] && LAST_STATUS="unknown"
ITERATION=$(extract "$LAST_EVENT" "iteration")
[ -z "$ITERATION" ] && ITERATION=1
STARTED_AT=$(extract "$START" "timestamp")
LAST_UPDATED=$(extract "$LAST_EVENT" "timestamp")

# Цикл берётся из самого события: dev-события поля `loop` не несут вовсе, и это
# намеренно — старые трейлы читаются как раньше, без единой правки формата.
LOOP=$(extract "$LAST_EVENT" "loop")
[ -z "$LOOP" ] && LOOP="dev"

# Тестовый цикл — не переименованный dev-цикл, а другой процесс: acceptance
# criteria там тест-модель, а не SDD, и возвращаться из ревью надо либо к
# перегенерации сценариев, либо к правке ожиданий человеком.
# `iterate` по контракту phase-transition.schema.json — «ещё одна попытка в той
# же фазе», и рекомендация обязана вести именно туда. Обрабатывается до разбора
# фаз, иначе каждая фаза дублировала бы одну и ту же строку, а половина из них
# отправляла бы в начало цикла.
# Цикл обязателен: фаза `review` есть в обоих словарях, и без него тестовая
# итерация уводила бы в /review — команду ревью кода.
same_phase_cmd() {
  local loop="$1"; local phase="$2"
  if [ "$loop" = "testing" ]; then
    case "$phase" in
      profile)   echo "/test-project" ;;
      model)     echo "/generate-test-cases" ;;
      autotests) echo "/generate-autotests" ;;
      review)    echo "/review-autotests" ;;
      run)       echo "/test-run" ;;
      export)    echo "/export-testcases-xml" ;;
      *)         echo "" ;;
    esac
    return
  fi
  case "$phase" in
    plan)      echo "/plan" ;;
    test)      echo "/test" ;;
    implement) echo "/implement" ;;
    review)    echo "/review" ;;
    evidence)  echo "/evidence" ;;
    *)         echo "" ;;
  esac
}

next_cmd_testing() {
  local phase="$1"; local status="$2"
  case "$phase" in
    profile)
      [ "$status" = "pass" ] && echo "/generate-test-cases" && return
      echo "/test-project" ;;
    model)
      [ "$status" = "pass" ] && echo "/generate-autotests" && return
      echo "/generate-test-cases" ;;
    autotests)
      [ "$status" = "pass" ] && echo "/review-autotests" && return
      [ "$status" = "iterate" ] && echo "/generate-autotests" && return
      echo "/generate-autotests" ;;
    review)
      # Барьер: прогон закрыт, пока разработка по story не дошла до implemented.
      # Рекомендовать сразу /test-run значит послать в гейт, который его не
      # пропустит, — и заставить разбираться уже в отказе.
      [ "$status" = "pass" ] && echo "/release-readiness" && return
      # escalate — находки не чинятся механически: правится тест-модель, а это
      # решение человека.
      [ "$status" = "escalate" ] && echo "/generate-test-cases" && return
      # fail — откат на предыдущую фазу (см. таблицу откатов /test-workflow):
      # channel-drift и polarity-drift чинятся перегенерацией, а не ещё одним
      # ревью того же самого.
      echo "/generate-autotests" ;;
    run)
      [ "$status" = "pass" ] && echo "/export-testcases-xml" && return
      [ "$status" = "escalate" ] && echo "/generate-test-cases" && return
      echo "/generate-autotests" ;;
    export)
      [ "$status" = "pass" ] && echo "(complete)" && return
      echo "/export-testcases-xml" ;;
    done) echo "(complete)" ;;
    *) echo "/test-project" ;;
  esac
}

# Compute next_recommended_command — derived from current_phase + status
next_cmd() {
  local phase="$1"; local status="$2"
  case "$phase" in
    plan)
      [ "$status" = "pass" ] && echo "/test" && return
      echo "/sdd-new" ;;
    test)
      [ "$status" = "pass" ] && echo "/implement" && return
      echo "/sdd-new" ;;
    implement)
      [ "$status" = "pass" ] && echo "/review" && return
      [ "$status" = "iterate" ] && echo "/implement" && return
      [ "$status" = "escalate" ] && echo "/sdd-new" && return
      echo "/implement" ;;
    review)
      [ "$status" = "pass" ] && echo "/evidence" && return
      echo "/implement" ;;
    evidence)
      [ "$status" = "pass" ] && echo "/squash" && return
      echo "/evidence" ;;
    done) echo "(complete)" ;;
    *) echo "/sdd-new" ;;
  esac
}

NEXT=""
if [ "$LAST_STATUS" = "iterate" ]; then
  NEXT=$(same_phase_cmd "$LOOP" "$CURRENT_PHASE")
fi
if [ -z "$NEXT" ]; then
  if [ "$LOOP" = "testing" ]; then
    NEXT=$(next_cmd_testing "$CURRENT_PHASE" "$LAST_STATUS")
  else
    NEXT=$(next_cmd "$CURRENT_PHASE" "$LAST_STATUS")
  fi
fi

# Output
if [ "$FORMAT" = "json" ]; then
  printf '{"task_id":"%s","loop":"%s","current_phase":"%s","last_status":"%s","iteration":%s,"started_at":"%s","last_updated":"%s","next_recommended_command":"%s","total_events":%d}\n' \
    "$TASK_ID" "$LOOP" "$CURRENT_PHASE" "$LAST_STATUS" "$ITERATION" "$STARTED_AT" "$LAST_UPDATED" "$NEXT" "$TOTAL"
else
  if [ -t 1 ]; then
    C_CYAN=$'\033[0;36m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_RESET=""
  fi
  printf '%sWorkflow state — %s%s\n' "$C_CYAN" "$TASK_ID" "$C_RESET"
  printf '  %sLoop:%s             %s\n' "$C_DIM" "$C_RESET" "$LOOP"
  printf '  %sCurrent phase:%s    %s\n' "$C_DIM" "$C_RESET" "$CURRENT_PHASE"
  printf '  %sLast status:%s      %s\n' "$C_DIM" "$C_RESET" "$LAST_STATUS"
  printf '  %sIteration:%s        %s\n' "$C_DIM" "$C_RESET" "$ITERATION"
  printf '  %sStarted:%s          %s\n' "$C_DIM" "$C_RESET" "$STARTED_AT"
  printf '  %sLast updated:%s     %s\n' "$C_DIM" "$C_RESET" "$LAST_UPDATED"
  printf '  %sTotal events:%s     %d\n' "$C_DIM" "$C_RESET" "$TOTAL"
  printf '\n  %sNext recommended:%s  %s%s%s <task-id>\n' "$C_YELLOW" "$C_RESET" "$C_GREEN" "$NEXT" "$C_RESET"
fi

exit 0
