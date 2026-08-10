#!/usr/bin/env bash
# destructive-command-blocker.sh (v2 — risk-aware)
# PreToolUse hook для Bash. Defense-in-depth поверх permissions.deny из settings.json.
# Согласно §4.4 + §4.5 PDLC v3.5.
#
# v2 отличие: блокировки зависят от текущего risk class (R0..R5),
# который читается из .gigacode/.cost/current-risk-class.
# Чем выше R, тем шире список запретов.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

RISK_FILE=".gigacode/.cost/current-risk-class"
RISK_CLASS="R1"
if [[ -f "$RISK_FILE" ]]; then
  RISK_CLASS=$(cat "$RISK_FILE" 2>/dev/null | tr -d '[:space:]')
fi
if ! [[ "$RISK_CLASS" =~ ^R[0-5]$ ]]; then
  RISK_CLASS="R1"
fi

# === BASE: always-blocked (любой R-класс) ===
ALWAYS_DANGEROUS=(
  'rm -rf /'
  'rm -rf ~'
  'rm -rf \*'
  'git push.*--force'
  'git push.*-f[^a-z]'
  'git reset --hard origin'
  ':\(\)\{ :\|:& \};:'
  'mkfs\.'
  'dd if=.*of=/dev/'
  'chmod -R 777 /'
  '> /dev/sda'
  'curl.*\| *sh'
  'wget.*\| *sh'
)

# === R2+ дополнения ===
R2_DANGEROUS=(
  'npm publish'
  'pip install.*--user'
  'docker push'
)

# === R3+ дополнения ===
R3_DANGEROUS=(
  'terraform apply'
  'kubectl apply'
  'kubectl delete'
  'aws .*delete'
  'aws .*put-object.*credentials'
)

# === R4+ дополнения (фактически любая мутация требует human approval) ===
R4_DANGEROUS=(
  'psql.*-c .*DROP'
  'psql.*-c .*DELETE'
  'psql.*-c .*UPDATE'
  'mongo.*\.drop\('
  'redis-cli.*FLUSHALL'
)

# === R5: всё, что не явно read-only ===
R5_READONLY_ALLOWED=(
  '^git status'
  '^git diff'
  '^git log'
  '^ls '
  '^cat '
  '^grep '
  '^npm test'
  '^pytest'
  '^go test'
)

# Помощник: проверить command против массива паттернов и block при match
check_patterns() {
  local label="$1"
  shift
  for pattern in "$@"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
      cat >&2 <<EOF
{"decision": "block", "reason": "Destructive command blocked by $label for risk class $RISK_CLASS. Pattern: '$pattern'. Command: '$COMMAND'. §4.4 + §4.5 PDLC v3.5. To proceed: lower risk class with justification, or request human approval."}
EOF
      exit 2
    fi
  done
}

# Всегда блокируем базовый набор
check_patterns "BASE policy" "${ALWAYS_DANGEROUS[@]}"

# Эскалация по R-классу
case "$RISK_CLASS" in
  R2|R3|R4|R5)
    check_patterns "R2+ policy" "${R2_DANGEROUS[@]}"
    ;;
esac

case "$RISK_CLASS" in
  R3|R4|R5)
    check_patterns "R3+ policy" "${R3_DANGEROUS[@]}"
    ;;
esac

case "$RISK_CLASS" in
  R4|R5)
    check_patterns "R4+ policy" "${R4_DANGEROUS[@]}"
    ;;
esac

# R5: deny-by-default. Allow только если команда матчит read-only allowlist.
if [[ "$RISK_CLASS" == "R5" ]]; then
  is_allowed=0
  for pattern in "${R5_READONLY_ALLOWED[@]}"; do
    if echo "$COMMAND" | grep -qE "$pattern"; then
      is_allowed=1
      break
    fi
  done
  if [[ "$is_allowed" -eq 0 ]]; then
    cat >&2 <<EOF
{"decision": "block", "reason": "Risk class R5 (regulated risk logic) requires human-driven Bash. Command '$COMMAND' is not in the read-only allowlist. §4.5 PDLC v3.5: R5 autonomy = change_advisory_board, no autonomous Bash."}
EOF
    exit 2
  fi
fi

exit 0
