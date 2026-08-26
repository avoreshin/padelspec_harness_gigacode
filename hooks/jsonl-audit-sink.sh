#!/usr/bin/env bash
# jsonl-audit-sink.sh
# Универсальный append-only sink для JSONL audit trail (§5.7 PDLC v3.5).
# Подключается к любому событию (PostToolUse, SubagentStop, Stop, ...) и пишет
# одну JSON-строку в .gigacode/audit/<YYYY-MM-DD>.jsonl
#
# Append-only: файл открывается через >> и никогда не перезаписывается.
# Ротация — по дате.
#
# Поля записи зависят от audit_depth текущего risk class.
# audit_schemas описаны в policies/risk-ladder.yaml.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

AUDIT_DIR=".gigacode/audit"
mkdir -p "$AUDIT_DIR"

DATE=$(date -u +"%Y-%m-%d")
TS=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
FILE="$AUDIT_DIR/$DATE.jsonl"

INPUT="$(hook_input)"

# === extract event metadata ===
# Имя события во всех рантаймах — hook_event_name. Прежние .event / .hook_event
# не существуют нигде, поэтому каждая строка аудита писалась как event:"unknown";
# оставлены как fallback ради уже накопленных трейлов и синтетических фикстур.
EVENT_TYPE="$(hook_field_any '.hook_event_name' '.event' '.hook_event')"
[[ -n "$EVENT_TYPE" ]] || EVENT_TYPE="unknown"
TOOL="$(hook_field_any '.tool_name' '.tool')"
# agent_type присутствует только у субагентных событий; для главного цикла пусто.
AGENT="$(hook_field_any '.agent_type' '.subagent.name' '.agent')"
[[ -n "$AGENT" ]] || AGENT="main"
DECISION="$(hook_field '.decision')"
[[ -n "$DECISION" ]] || DECISION="allow"
SESSION_ID="$(hook_field '.session_id')"
TOOL_USE_ID="$(hook_field_any '.tool_use_id' '.tool_call_id')"

# === current risk class ===
RISK_CLASS="R1"
if [[ -f ".gigacode/.cost/current-risk-class" ]]; then
  RISK_CLASS=$(tr -d '[:space:]' < .gigacode/.cost/current-risk-class 2>/dev/null || echo "R1")
fi
[[ "$RISK_CLASS" =~ ^R[0-5]$ ]] || RISK_CLASS="R1"

# === audit depth → какие поля сохранить ===
# Минимум всегда: timestamp, agent, tool, decision, risk_class.
# R2+ добавляет diff_summary_hash и test_status.
# R3+ добавляет security_verdict.
# R4+ добавляет human_signoff_id.
# R5 добавляет cab_decision_id и regulatory_eval_id.

# Базовые поля (всегда).
BASE=$(jq -nc \
  --arg ts "$TS" \
  --arg ev "$EVENT_TYPE" \
  --arg ag "$AGENT" \
  --arg tl "$TOOL" \
  --arg dc "$DECISION" \
  --arg rc "$RISK_CLASS" \
  --arg sid "$SESSION_ID" \
  --arg tuid "$TOOL_USE_ID" \
  '{
    timestamp: $ts,
    event:     $ev,
    agent:     $ag,
    tool:      $tl,
    decision:  $dc,
    risk_class: $rc
  }
  + (if $sid  == "" then {} else {session_id:  $sid}  end)
  + (if $tuid == "" then {} else {tool_use_id: $tuid} end)')

# Опциональные поля из bundle, если доступен.
BUNDLE=".gigacode/evidence-bundle.json"
EXTRA="{}"
if [[ -f "$BUNDLE" ]]; then
  case "$RISK_CLASS" in
    R2|R3|R4|R5)
      EXTRA=$(jq -c '{
        test_status:      .tests.status,
        diff_summary:     (.diff_summary | {files_changed, additions, deletions})
      }' "$BUNDLE" 2>/dev/null || echo "{}")
      ;;
  esac
  case "$RISK_CLASS" in
    R3|R4|R5)
      SEC=$(jq -c '{
        security_verdict: .security_verdict.verdict,
        security_findings_count: (
          (.security_verdict.findings.critical // []) | length
        )
      }' "$BUNDLE" 2>/dev/null || echo "{}")
      EXTRA=$(echo "$EXTRA $SEC" | jq -s 'add')
      ;;
  esac
  case "$RISK_CLASS" in
    R4|R5)
      SIGN=$(jq -c '{
        human_signoff_id: .human_signoff.signoff_id,
        approver:         .human_signoff.approver
      }' "$BUNDLE" 2>/dev/null || echo "{}")
      EXTRA=$(echo "$EXTRA $SIGN" | jq -s 'add')
      ;;
  esac
  if [[ "$RISK_CLASS" == "R5" ]]; then
    CAB=$(jq -c '{
      cab_decision_id:   .cab_decision.decision_id,
      regulatory_status: .regulatory_eval_results.status
    }' "$BUNDLE" 2>/dev/null || echo "{}")
    EXTRA=$(echo "$EXTRA $CAB" | jq -s 'add')
  fi
fi

# === финальная запись ===
RECORD=$(echo "$BASE $EXTRA" | jq -sc 'add')

# Append. Никогда не перезаписываем.
echo "$RECORD" >> "$FILE"

# Не блокируем — это observability sink, не gate.
exit 0
