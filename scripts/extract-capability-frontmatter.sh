#!/usr/bin/env bash
# extract-capability-frontmatter.sh — specs/<capability>.md → capability-spec.schema.json-compatible JSON.
#
# Source SDD: docs/sdd/20260801-specs-layer-spike.md (R2, approved) — инкремент 1.
# Использование: scripts/extract-capability-frontmatter.sh <path-to-specs/<cap>.md>
#
# Извлекает:
#   - Metadata-таблицу (capability, version, status, owner, last_archived_change, last_update)
#   - requirements — массив заголовков "### REQ-*"
#   - invariants — массив "**INV-***"
#   - has_requirements / has_invariants — section-флаги
#
# Output: JSON на stdout. Зеркалит паттерн scripts/extract-dora-frontmatter.sh.

set -u

[ $# -lt 1 ] && { echo '{"error":"usage: extract-capability-frontmatter.sh <file.md>"}' >&2; exit 2; }
FILE="$1"
[ -f "$FILE" ] || { echo "{\"error\":\"file not found: $FILE\"}" >&2; exit 2; }

json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

strip_md() {
  printf '%s' "$1" | sed -E 's/\*\*//g; s/`//g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Read field from Metadata table: `| field | value |`
get_meta() {
  local field="$1"
  awk -F'|' -v f="$field" '
    BEGIN { IGNORECASE = 1 }
    /^\| / && tolower($2) ~ ("^[ \t]*" tolower(f) "[ \t]*$") {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$FILE"
}

# Array of "### <prefix>N: title" headings → JSON array of "prefixN: title"
extract_headings() {
  local prefix="$1"  # e.g. REQ-
  grep -E "^### ${prefix}[0-9]+" "$FILE" 2>/dev/null | sed -E 's/^### //' | awk '
    BEGIN { printf "["; first = 1 }
    {
      if (!first) printf ","
      first = 0
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      sub(/[[:space:]]+$/, "")
      printf "\"%s\"", $0
    }
    END { printf "]" }
  '
}

# Array of "**INV-N** ..." bullets → JSON array
extract_invariants() {
  grep -E '\*\*INV-[0-9]+' "$FILE" 2>/dev/null | sed -E 's/^[-*[:space:]]+//; s/\*\*//g' | awk '
    BEGIN { printf "["; first = 1 }
    {
      if (!first) printf ","
      first = 0
      gsub(/\\/, "\\\\")
      gsub(/"/, "\\\"")
      sub(/[[:space:]]+$/, "")
      printf "\"%s\"", $0
    }
    END { printf "]" }
  '
}

has() { grep -qE "$1" "$FILE" && echo true || echo false; }

CAPABILITY="$(strip_md "$(get_meta capability)")"
VERSION="$(strip_md "$(get_meta version)")"
STATUS="$(strip_md "$(get_meta status)")"
OWNER="$(strip_md "$(get_meta owner)")"
LAST_CHANGE="$(strip_md "$(get_meta last_archived_change)")"
LAST_UPDATE="$(strip_md "$(get_meta last_update)")"

REQ_ARRAY="$(extract_headings 'REQ-')"
[ -z "$REQ_ARRAY" ] && REQ_ARRAY='[]'
INV_ARRAY="$(extract_invariants)"
[ -z "$INV_ARRAY" ] && INV_ARRAY='[]'

cat <<EOF
{
  "capability": $(json_str "$CAPABILITY"),
  "version": $(json_str "$VERSION"),
  "status": $(json_str "$STATUS"),
  "owner": $(json_str "$OWNER"),
  "last_archived_change": $(json_str "$LAST_CHANGE"),
  "last_update": $(json_str "$LAST_UPDATE"),
  "requirements": $REQ_ARRAY,
  "invariants": $INV_ARRAY,
  "sections": {
    "has_requirements": $(has '^## Requirements'),
    "has_invariants":   $(has '^## Invariants')
  }
}
EOF
