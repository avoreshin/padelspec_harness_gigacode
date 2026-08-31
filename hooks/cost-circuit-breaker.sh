#!/usr/bin/env bash
# cost-circuit-breaker.sh
# PreToolUse hook: блокирует tool call, если task token budget исчерпан.
# Согласно §4.4 AI DISRUPT PDLC v3.5, hook "PreToolUse / cost-circuit-breaker".
#
# Логика:
#   1. Читает текущий token_count из счётчика (.gigacode/.cost/task-tokens).
#   2. Читает risk class задачи из .gigacode/.cost/current-risk-class
#      (по умолчанию R1).
#   3. Сверяет с лимитом из policies/risk-ladder.yaml.
#   4. Превышено → block с структурированным reason.
#   5. ≥ 80% бюджета → warning в stderr, но allow.
#
# Счётчик обновляется отдельной утилитой /metrics или внешним sidecar'ом.
# Этот hook — gate, не accountant.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

# Счётчик и ladder лежат в корне проекта: без резолва хук, запущенный из
# подкаталога, создал бы второй каталог состояния и всегда видел бы 0 токенов.
cd_harness_root

COST_DIR=".gigacode/.cost"
TOKEN_FILE="$COST_DIR/task-tokens"
RISK_FILE="$COST_DIR/current-risk-class"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
LADDER="$HARNESS_ROOT/policies/risk-ladder.yaml"

mkdir -p "$COST_DIR"

# === STEP 1: текущий counter ===
CURRENT_TOKENS=0
if [[ -f "$TOKEN_FILE" ]]; then
  CURRENT_TOKENS=$(cat "$TOKEN_FILE" 2>/dev/null || echo 0)
fi
# Sanitize: только цифры
if ! [[ "$CURRENT_TOKENS" =~ ^[0-9]+$ ]]; then
  CURRENT_TOKENS=0
fi

# === STEP 2: текущий risk class ===
RISK_CLASS="R1"
if [[ -f "$RISK_FILE" ]]; then
  RISK_CLASS=$(tr -d '[:space:]' < "$RISK_FILE" 2>/dev/null || echo "R1")
fi
if ! [[ "$RISK_CLASS" =~ ^R[0-5]$ ]]; then
  RISK_CLASS="R1"
fi

# === STEP 3: лимит из ladder ===
# Парсим YAML минималистично — без зависимости от yq.
# Извлекаем строку вида "    token_budget: NNNN" внутри блока R<N>:
BUDGET=$(awk -v cls="^  $RISK_CLASS:" '
  $0 ~ cls { in_block = 1; next }
  in_block && /^  [A-Z][0-9]:/ { in_block = 0 }
  in_block && /^    token_budget:/ {
    gsub(/[^0-9]/, "", $2)
    print $2
    exit
  }
' "$LADDER" 2>/dev/null)

# Fallback на безопасный дефолт
if ! [[ "$BUDGET" =~ ^[0-9]+$ ]] || [[ -z "$BUDGET" ]]; then
  BUDGET=200000
fi

# === STEP 4: gate ===
if [[ "$CURRENT_TOKENS" -ge "$BUDGET" ]]; then
  deny "Cost circuit breaker tripped. Risk class $RISK_CLASS, budget $BUDGET tokens, consumed $CURRENT_TOKENS. Either: (1) finalize current task and /evidence, (2) escalate risk class with justification, (3) request budget increase via human review. §4.4 PDLC v3.5."
fi

# === STEP 5: 80% warning ===
THRESHOLD=$(( BUDGET * 80 / 100 ))
if [[ "$CURRENT_TOKENS" -ge "$THRESHOLD" ]]; then
  PERCENT=$(( CURRENT_TOKENS * 100 / BUDGET ))
  echo "[cost-circuit-breaker] Warning: ${PERCENT}% of $RISK_CLASS budget consumed ($CURRENT_TOKENS / $BUDGET). Consider /evidence soon." >&2
fi

exit 0
