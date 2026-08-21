#!/usr/bin/env bash
# context-integrity-review.sh
# PreCompact hook: сохраняет critical state перед сжатием контекста.
# Согласно §2.10 (5-уровневое сжатие) и §4.4 PDLC v3.5.
#
# Когда срабатывает:
#   Перед уровнями 3-5 сжатия (Microcompact / Context collapse / Auto-compact)
#   harness вызывает этот hook. Hook должен:
#     1. Снять snapshot текущего состояния (open SDD, current risk class,
#        pending failing tests, last subagent verdicts).
#     2. Записать в .gigacode/.context-snapshots/<timestamp>.json
#     3. Проверить, что ничто из protected_state не теряется при сжатии.
#     4. Если теряется — block + reason.
#
# Это последний шанс не потерять критическое состояние между фазами.

set -euo pipefail

# jq обязателен: без него хук молча пропускал бы вызов (см. lib/require-jq.sh).
source "${BASH_SOURCE[0]%/*}/lib/require-jq.sh" || exit 2

SNAPSHOT_DIR=".gigacode/.context-snapshots"
mkdir -p "$SNAPSHOT_DIR"

INPUT=$(cat)
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
SNAPSHOT_FILE="$SNAPSHOT_DIR/$TIMESTAMP.json"

# === STEP 1: extract compact metadata ===
COMPACT_LEVEL=$(echo "$INPUT" | jq -r '.compact.level // "unknown"')
TOKENS_BEFORE=$(echo "$INPUT" | jq -r '.compact.tokens_before // 0')
TOKENS_AFTER=$(echo "$INPUT" | jq -r '.compact.tokens_after // 0')

# === STEP 2: gather protected state ===
RISK_CLASS=$(cat .gigacode/.cost/current-risk-class 2>/dev/null || echo "unknown")
ACTIVE_SDD=$(ls -t docs/sdd/*.md 2>/dev/null | head -1 || echo "none")
EVIDENCE_BUNDLE_EXISTS="false"
[[ -f ".gigacode/evidence-bundle.json" ]] && EVIDENCE_BUNDLE_EXISTS="true"

# Pending failing tests — последняя строка из test runner cache, если есть.
LAST_TEST_STATUS="unknown"
if [[ -f ".gigacode/.cache/last-test-run.txt" ]]; then
  LAST_TEST_STATUS=$(tail -1 .gigacode/.cache/last-test-run.txt 2>/dev/null || echo "unknown")
fi

# === STEP 3: write snapshot ===
cat > "$SNAPSHOT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "compact_level": "$COMPACT_LEVEL",
  "tokens_before": $TOKENS_BEFORE,
  "tokens_after": $TOKENS_AFTER,
  "protected_state": {
    "risk_class": "$RISK_CLASS",
    "active_sdd": "$ACTIVE_SDD",
    "evidence_bundle_present": $EVIDENCE_BUNDLE_EXISTS,
    "last_test_status": "$LAST_TEST_STATUS"
  },
  "pdlc_ref": "§2.10, §4.4"
}
EOF

# === STEP 4: integrity check ===
# Если идём в level 5 (auto-compact, full summary) и есть pending failing
# tests — это плохая идея. Заставляем человека либо запустить /evidence,
# либо явно подтвердить.
if [[ "$COMPACT_LEVEL" == "5" || "$COMPACT_LEVEL" == "auto-compact" ]]; then
  if [[ "$LAST_TEST_STATUS" == "failed" || "$LAST_TEST_STATUS" == "red" ]]; then
    cat >&2 <<EOF
{"decision": "block", "reason": "Pre-compact at level 5 with failing tests detected. Snapshot saved to $SNAPSHOT_FILE. Resolve failing tests, run /evidence, or explicitly approve loss of test context. §2.10 PDLC v3.5."}
EOF
    exit 2
  fi
fi

# Если SDD утерян из контекста, а risk class ≥ R3 — block.
if [[ "$RISK_CLASS" =~ ^R[3-5]$ ]] && [[ "$ACTIVE_SDD" == "none" ]]; then
  cat >&2 <<EOF
{"decision": "block", "reason": "Pre-compact with risk class $RISK_CLASS but no active SDD found in docs/sdd/. SDD must be present for R3+ tasks. Snapshot saved to $SNAPSHOT_FILE. §4.5 PDLC v3.5."}
EOF
  exit 2
fi

echo "[context-integrity] Snapshot saved: $SNAPSHOT_FILE (level=$COMPACT_LEVEL, risk=$RISK_CLASS)" >&2
exit 0
