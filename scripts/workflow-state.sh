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

NEXT=$(next_cmd "$CURRENT_PHASE" "$LAST_STATUS")

# Output
if [ "$FORMAT" = "json" ]; then
  printf '{"task_id":"%s","current_phase":"%s","last_status":"%s","iteration":%s,"started_at":"%s","last_updated":"%s","next_recommended_command":"%s","total_events":%d}\n' \
    "$TASK_ID" "$CURRENT_PHASE" "$LAST_STATUS" "$ITERATION" "$STARTED_AT" "$LAST_UPDATED" "$NEXT" "$TOTAL"
else
  if [ -t 1 ]; then
    C_CYAN=$'\033[0;36m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
  else
    C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_RESET=""
  fi
  printf '%sWorkflow state — %s%s\n' "$C_CYAN" "$TASK_ID" "$C_RESET"
  printf '  %sCurrent phase:%s    %s\n' "$C_DIM" "$C_RESET" "$CURRENT_PHASE"
  printf '  %sLast status:%s      %s\n' "$C_DIM" "$C_RESET" "$LAST_STATUS"
  printf '  %sIteration:%s        %s\n' "$C_DIM" "$C_RESET" "$ITERATION"
  printf '  %sStarted:%s          %s\n' "$C_DIM" "$C_RESET" "$STARTED_AT"
  printf '  %sLast updated:%s     %s\n' "$C_DIM" "$C_RESET" "$LAST_UPDATED"
  printf '  %sTotal events:%s     %d\n' "$C_DIM" "$C_RESET" "$TOTAL"
  printf '\n  %sNext recommended:%s  %s%s%s <task-id>\n' "$C_YELLOW" "$C_RESET" "$C_GREEN" "$NEXT" "$C_RESET"
fi

exit 0
