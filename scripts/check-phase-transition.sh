#!/usr/bin/env bash
# check-phase-transition.sh — извлечь structured phase output из agent answer
# и провалидировать против phase-transition.schema.json.
#
# Source SDD: docs/sdd/20260522-phase-gate-protocol.md (R1, approved 2026-05-22),
# AC-6 — SDD живёт в рабочем репозитории pdlc-harness-work.
#
# Usage:
#   .gigacode/scripts/check-phase-transition.sh <agent-output-file>
#   cat agent.txt | .gigacode/scripts/check-phase-transition.sh -    # stdin
#
# Looks for marker:
#   <!-- phase-transition:json -->
#   <pre>
#   { ... json ... }
#   </pre>
#
# OR (compact form):
#   <!-- phase-transition:json -->{ ... json ... }<!-- /phase-transition -->
#
# Exit codes:
#   0 — marker found, JSON parsed, schema valid
#   1 — marker found, JSON invalid (schema fail)
#   2 — marker absent OR usage error

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

SCHEMA=".gigacode/schemas/phase-transition.schema.json"
if [ ! -f "$SCHEMA" ]; then
  echo "error: schema not found: $SCHEMA" >&2; exit 2
fi

if [ "$#" -lt 1 ]; then
  cat >&2 <<'EOF'
usage: check-phase-transition.sh <file>
   or: check-phase-transition.sh -      (read from stdin)

Searches for a <!-- phase-transition:json --> ... </pre> block in agent
output and validates the JSON payload against phase-transition.schema.json.

Exit codes:
  0 — marker found, JSON valid against schema
  1 — marker found, but JSON fails schema
  2 — marker absent OR usage / internal error
EOF
  exit 2
fi

if [ "$1" = "-" ]; then
  INPUT="$(cat)"
else
  if [ ! -f "$1" ]; then
    echo "error: file not found: $1" >&2; exit 2
  fi
  INPUT="$(cat "$1")"
fi

# Extract between <!-- phase-transition:json --> and </pre> (or closing comment).
# Use awk for portability across BSD/GNU sed.
JSON="$(printf '%s' "$INPUT" | awk '
  /<!-- phase-transition:json -->/ { capture=1; sub(/.*<!-- phase-transition:json -->/, ""); }
  capture {
    line=$0
    if (match(line, /<\/pre>|<!-- \/phase-transition -->/)) {
      sub(/<\/pre>.*|<!-- \/phase-transition -->.*/, "", line)
      print line
      exit
    }
    print line
  }
')"

# Strip surrounding <pre> tags and whitespace
JSON="$(printf '%s' "$JSON" | sed -E 's/<pre>//; s|</pre>||' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

if [ -z "$JSON" ]; then
  echo "error: phase-transition marker absent in input" >&2
  exit 2
fi

# Write to temp .json file so _validator.js can detect format
TMP="$(mktemp -t pt-XXXXXX)"
mv "$TMP" "$TMP.json"
TMP="$TMP.json"
# Оба явных rm ниже стоят на успешной и на неуспешной ветке, но не переживают
# прерывание и падение валидатора.
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$JSON" > "$TMP"

if node .gigacode/scripts/_validator.js validate "$SCHEMA" "$TMP" >/dev/null 2>&1; then
  echo "✓ phase-transition: valid"
  rm -f "$TMP"
  exit 0
else
  echo "✗ phase-transition: schema fail" >&2
  node .gigacode/scripts/_validator.js validate "$SCHEMA" "$TMP" 2>&1 | head -5 >&2
  rm -f "$TMP"
  exit 1
fi
