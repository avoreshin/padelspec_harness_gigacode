#!/usr/bin/env bash
# subagent-stop-validator.sh
# SubagentStop hook: проверяет, что subagent выполнил свой mandate
# и не вышел за tool scope.
# Согласно §4.4 PDLC v3.5 (Policy Hook Framework) и §2.11 (Subagents as isolation).
#
# Что проверяет:
#   1. Subagent с именем X использовал только tools, разрешённые его профилем
#      в .gigacode/agents/<X>.md (frontmatter `tools:`).
#   2. Output subagent'а соответствует контракту (минимальные обязательные секции).
#   3. Для security subagent с risk class R3+ — verdict присутствует и не EMPTY.
#
# Block → subagent run перезапускается parent'ом с уточнённым промптом.

set -euo pipefail

# jq обязателен: без него хук молча пропускал бы вызов (см. lib/require-jq.sh).
source "${BASH_SOURCE[0]%/*}/lib/require-jq.sh" || exit 2

INPUT=$(cat)
AGENT_NAME=$(echo "$INPUT" | jq -r '.subagent.name // ""')
TOOLS_USED=$(echo "$INPUT" | jq -r '.subagent.tools_used // [] | join(",")')
OUTPUT=$(echo "$INPUT" | jq -r '.subagent.output // ""')

if [[ -z "$AGENT_NAME" ]]; then
  # Не subagent или нет имени — пропускаем.
  exit 0
fi

PROFILE=".gigacode/agents/$AGENT_NAME.md"
if [[ ! -f "$PROFILE" ]]; then
  echo "[subagent-stop-validator] Unknown subagent: $AGENT_NAME (no profile in .gigacode/agents/)" >&2
  exit 0
fi

# === STEP 1: tool scope из frontmatter ===
# Извлекаем строку `tools: A, B, C` из YAML frontmatter.
ALLOWED_TOOLS=$(awk '
  /^---/ { fm = !fm; next }
  fm && /^tools:/ {
    sub(/^tools:[[:space:]]*/, "")
    print
    exit
  }
' "$PROFILE")

# Нормализуем: убираем пробелы.
ALLOWED_NORM=$(echo "$ALLOWED_TOOLS" | tr -d '[:space:]')
USED_NORM=$(echo "$TOOLS_USED" | tr -d '[:space:]')

# === STEP 2: каждый used tool — в allowed? ===
if [[ -n "$USED_NORM" ]]; then
  IFS=',' read -ra USED_ARR <<< "$USED_NORM"
  for tool in "${USED_ARR[@]}"; do
    [[ -z "$tool" ]] && continue
    if ! echo ",$ALLOWED_NORM," | grep -q ",$tool,"; then
      cat >&2 <<EOF
{"decision": "block", "reason": "Subagent '$AGENT_NAME' used tool '$tool' which is NOT in its declared scope ($ALLOWED_TOOLS). This violates §2.11 (subagent scope is narrower than parent). Profile: $PROFILE."}
EOF
      exit 2
    fi
  done
fi

# === STEP 3: output contract checks по имени subagent ===
case "$AGENT_NAME" in
  explore)
    # должен быть Scope + Findings
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Scope"; then
      echo "{\"decision\": \"block\", \"reason\": \"Explore output missing '## Scope' section. See .gigacode/agents/explore.md contract.\"}" >&2
      exit 2
    fi
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Findings"; then
      echo "{\"decision\": \"block\", \"reason\": \"Explore output missing '## Findings' section.\"}" >&2
      exit 2
    fi
    ;;
  plan)
    for sect in "Plan summary" "Risk class" "Implementation steps"; do
      if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*$sect"; then
        echo "{\"decision\": \"block\", \"reason\": \"Plan output missing '## $sect'. See .gigacode/agents/plan.md contract.\"}" >&2
        exit 2
      fi
    done
    ;;
  test)
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Tests added"; then
      echo "{\"decision\": \"block\", \"reason\": \"Test output missing '## Tests added'.\"}" >&2
      exit 2
    fi
    # Должно быть подтверждение запуска
    if ! echo "$OUTPUT" | grep -qiE "(failed|passed)"; then
      echo "{\"decision\": \"block\", \"reason\": \"Test output missing run result (no 'failed' or 'passed' keywords). TDD red requires evidence that tests actually ran.\"}" >&2
      exit 2
    fi
    ;;
  coding)
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Files changed"; then
      echo "{\"decision\": \"block\", \"reason\": \"Coding output missing '## Files changed'.\"}" >&2
      exit 2
    fi
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Self-check"; then
      echo "{\"decision\": \"block\", \"reason\": \"Coding output missing '## Self-check' block. See .gigacode/agents/coding.md contract.\"}" >&2
      exit 2
    fi
    # Defense: проверим, что coding не редактировал тесты.
    TESTS_TOUCHED=$(echo "$OUTPUT" | grep -cE "(tests/|_test\.|\.spec\.)" || true)
    if [[ "$TESTS_TOUCHED" -gt 0 ]]; then
      echo "{\"decision\": \"block\", \"reason\": \"Coding agent appears to have touched test files. This violates the §7 GIGACODE.md rule: tests are acceptance criteria, only the test agent may modify them.\"}" >&2
      exit 2
    fi
    ;;
  review)
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Verdict"; then
      echo "{\"decision\": \"block\", \"reason\": \"Review output missing '## Verdict'. Must be APPROVE/REQUEST_CHANGES/BLOCK.\"}" >&2
      exit 2
    fi
    VERDICT_LINE=$(echo "$OUTPUT" | awk '/^##[[:space:]]*Verdict/{flag=1; next} flag && NF{print; exit}')
    if ! echo "$VERDICT_LINE" | grep -qE "(APPROVE|REQUEST_CHANGES|BLOCK)"; then
      echo "{\"decision\": \"block\", \"reason\": \"Review verdict line must be one of APPROVE / REQUEST_CHANGES / BLOCK. Got: $VERDICT_LINE\"}" >&2
      exit 2
    fi
    ;;
  security)
    if ! echo "$OUTPUT" | grep -qE "^##[[:space:]]*Verdict"; then
      echo "{\"decision\": \"block\", \"reason\": \"Security output missing '## Verdict'. Must be PASS/FAIL/NEEDS_HUMAN_REVIEW.\"}" >&2
      exit 2
    fi
    VERDICT_LINE=$(echo "$OUTPUT" | awk '/^##[[:space:]]*Verdict/{flag=1; next} flag && NF{print; exit}')
    if ! echo "$VERDICT_LINE" | grep -qE "(PASS|FAIL|NEEDS_HUMAN_REVIEW)"; then
      echo "{\"decision\": \"block\", \"reason\": \"Security verdict line must be one of PASS / FAIL / NEEDS_HUMAN_REVIEW. Got: $VERDICT_LINE\"}" >&2
      exit 2
    fi
    ;;
esac

echo "[subagent-stop-validator] $AGENT_NAME passed contract check (tools_used=$TOOLS_USED)" >&2
exit 0
