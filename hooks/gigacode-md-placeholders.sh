#!/usr/bin/env bash
# gigacode-md-placeholders.sh
# SessionStart hook: warns when .gigacode/GIGACODE.md still contains unfilled
# <…> placeholders. After /init-project a few values are pre-set, but
# architecture, naming, R3 examples etc. are left for the operator to
# fill in. Without this hook those gaps stay invisible — the agent runs
# with a stack-agnostic guidance layer and no one notices until something
# goes wrong.
#
# Behaviour:
#   - warn (exit 0) by default — does not block the session
#   - block (exit 2) when GIGACODE_MD_STRICT=1 is set
#   - skip silently when .gigacode/GIGACODE.md doesn't exist

set -euo pipefail

GIGACODE_MD="${GIGACODE_MD_PATH:-.gigacode/GIGACODE.md}"

if [[ ! -f "$GIGACODE_MD" ]]; then
  exit 0
fi

# Find <…> placeholders. Excludes:
#   - <type>, <scope>, <subject> in the Conventional Commits example
#   - <feature> in path examples like docs/sdd/<feature>.md
#   - <ссылки>, <слова> if they're inside Markdown code blocks (heuristic: skip lines starting with `)
PLACEHOLDERS=$(awk '
  /^```/ { in_code = !in_code; next }
  in_code { next }
  /<type>|<scope>|<subject>|<feature>|<N>|<NNNN>|<slug>|<имя>|<SME, security, architect>/ { next }
  match($0, /<[^>]+>/) {
    line_no = NR
    snippet = substr($0, RSTART, RLENGTH)
    printf "  line %d: %s\n", line_no, snippet
  }
' "$GIGACODE_MD")

if [[ -z "$PLACEHOLDERS" ]]; then
  exit 0
fi

# Report.
{
  echo ""
  echo "⚠️  $GIGACODE_MD has unfilled placeholders:"
  echo "$PLACEHOLDERS"
  echo ""
  echo "Run /init-project with the missing flags, or edit the file directly."
  echo "These placeholders mean the agent has no idea about your stack/conventions."
} >&2

if [[ "${GIGACODE_MD_STRICT:-0}" == "1" ]]; then
  cat >&2 <<'EOF'
{"decision": "block", "reason": "GIGACODE_MD_STRICT=1 and GIGACODE.md has unfilled placeholders. Fill them or unset the strict flag."}
EOF
  exit 2
fi

exit 0
