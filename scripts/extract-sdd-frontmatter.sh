#!/usr/bin/env bash
# extract-sdd-frontmatter.sh — извлекает из SDD markdown в .gigacode/schemas/sdd.schema.json-compatible JSON.
#
# Source SDD: docs/sdd/20260520-schema-completeness.md (R1)
# (SDD живёт в рабочем репозитории pdlc-harness-work, сюда не бэкпортился)
# Использование: scripts/extract-sdd-frontmatter.sh <path-to-sdd.md>
#
# Извлекает:
#   - Metadata-таблицу (id, author, status, risk_class, created, ...)
#   - Goal text
#   - acceptance_criteria — массив строк AC-*
#   - property_based_invariants — массив строк INV-*
#   - definition_of_done — массив строк DoD-checkbox-ов
#   - наличие секций (флаги has_*)
#
# Output: JSON на stdout. Lenient parsing: case-insensitive fields, partial-match values.

set -u

[ $# -lt 1 ] && { echo '{"error":"usage: extract-sdd-frontmatter.sh <file.md>"}' >&2; exit 2; }
FILE="$1"
[ -f "$FILE" ] || { echo "{\"error\":\"file not found: $FILE\"}" >&2; exit 2; }

# Strip backticks/markdown emphasis из значения, trim
strip_md() {
  printf '%s' "$1" | sed -E 's/\*\*//g; s/`//g; s/_//g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

# JSON-escape a string (bash-only, no jq)
json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Parse Metadata table (lines like `| **Field** | value |`)
get_meta() {
  local field="$1"
  awk -F'|' -v f="$field" '
    BEGIN { IGNORECASE = 1 }
    /^\| / && tolower($0) ~ ("\\*\\*" tolower(f) "\\*\\*") {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$FILE"
}

# Count occurrences of pattern (for has_* flags and array length)
count_lines_matching() {
  local pat="$1"
  grep -cE "$pat" "$FILE" || true
}

# Extract array of strings matching a heading prefix (e.g. ### AC-1, ### AC-2, ...)
# Returns JSON array of section titles
extract_section_titles() {
  local prefix="$1"  # e.g. "AC-"
  local items=()
  while IFS= read -r line; do
    # Strip leading "### " / "#### " and trailing whitespace
    line="$(printf '%s' "$line" | sed -E "s/^#+[[:space:]]+//; s/[[:space:]]+$//")"
    items+=("$line")
  done < <(grep -E "^#+ +${prefix}[0-9]+" "$FILE" 2>/dev/null || true)

  if [ ${#items[@]} -eq 0 ]; then
    printf '[]'
    return
  fi

  local out="["
  local first=true
  for it in "${items[@]}"; do
    if $first; then first=false; else out+=","; fi
    out+="$(json_str "$it")"
  done
  out+="]"
  printf '%s' "$out"
}

# Extract DoD checkboxes (lines like "- [ ]" or "- [x]" inside section 13)
extract_dod() {
  awk '
    /^## 13\./ { in_dod = 1; next }
    /^## / && in_dod { exit }
    in_dod && /^- \[[ xX]\]/ {
      sub(/^- \[[ xX]\][[:space:]]+/, "")
      print
    }
  ' "$FILE"
}

# ---------------------------------------------------------------------------
# Extract fields
# ---------------------------------------------------------------------------

ID="$(strip_md "$(get_meta ID)")"
AUTHOR="$(strip_md "$(get_meta Author)")"
STATUS_RAW="$(strip_md "$(get_meta Status)")"
RISK_RAW="$(strip_md "$(get_meta 'Risk class')")"
CREATED="$(strip_md "$(get_meta Created)")"
LAST_UPDATE="$(strip_md "$(get_meta 'Last update')")"
REVIEWERS="$(strip_md "$(get_meta Reviewers)")"

# Status — normalize "approved", "draft", "implemented" из value (может быть "**approved** by ...")
STATUS="$(printf '%s' "$STATUS_RAW" | grep -oiE 'draft|approved|implemented|deprecated' | head -1 | tr '[:upper:]' '[:lower:]')"
[ -z "$STATUS" ] && STATUS="$STATUS_RAW"

# Risk class — normalize "R0".."R5"
RISK="$(printf '%s' "$RISK_RAW" | grep -oE 'R[0-5]' | head -1)"
[ -z "$RISK" ] && RISK="$RISK_RAW"

# Goal — первый non-empty параграф после "## 1. Goal"
GOAL="$(awk '
  /^## 1\. /                 { in_goal = 1; next }
  /^## / && in_goal          { exit }
  in_goal && NF              { print; exit }
' "$FILE")"

# Sections that contain `## 2. Non-goals`, etc., as boolean has_* flags
has_section() {
  grep -qE "^## $1\\. " "$FILE" && echo "true" || echo "false"
}

# Array extractions
AC_ARRAY="$(extract_section_titles 'AC-')"
INV_ARRAY="$(extract_section_titles 'INV-')"

# Если нет ### AC-1, попробовать **AC-1** в bullet-форме (некоторые SDD так пишут)
if [ "$AC_ARRAY" = "[]" ]; then
  AC_ARRAY="$(grep -E '\*\*AC-[0-9]+' "$FILE" 2>/dev/null | sed -E 's/.*(\*\*AC-[0-9]+[^*]*\*\*).*/\1/' | sed 's/\*//g' | awk '
    BEGIN { printf "["; first=1 }
    { if (!first) printf ","; first=0; gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0 }
    END { printf "]" }
  ')"
  [ -z "$AC_ARRAY" ] && AC_ARRAY='[]'
fi

if [ "$INV_ARRAY" = "[]" ]; then
  INV_ARRAY="$(grep -E '\*\*INV-[0-9]+' "$FILE" 2>/dev/null | sed -E 's/.*(\*\*INV-[0-9]+[^*]*\*\*).*/\1/' | sed 's/\*//g' | awk '
    BEGIN { printf "["; first=1 }
    { if (!first) printf ","; first=0; gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0 }
    END { printf "]" }
  ')"
  [ -z "$INV_ARRAY" ] && INV_ARRAY='[]'
fi

# DoD array
DOD_LINES=()
while IFS= read -r line; do
  [ -n "$line" ] && DOD_LINES+=("$line")
done < <(extract_dod)

DOD_ARRAY="["
first=true
for line in "${DOD_LINES[@]+"${DOD_LINES[@]}"}"; do
  if $first; then first=false; else DOD_ARRAY+=","; fi
  DOD_ARRAY+="$(json_str "$line")"
done
DOD_ARRAY+="]"

# Risk class rationale text (from § 8 if present)
RISK_RATIONALE="$(awk '
  /^## 8\./ { in_r = 1; next }
  /^## /    { in_r = 0 }
  in_r && NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
' "$FILE")"

has_goal=$(has_section 1)
has_nongoals=$(has_section 2)
has_ac=$(has_section 4)
has_inv=$(has_section 5)
has_risk=$(has_section 8)
has_dod=$(has_section 13)

# ---------------------------------------------------------------------------
# Emit JSON
# ---------------------------------------------------------------------------

cat <<EOF
{
  "id": $(json_str "$ID"),
  "author": $(json_str "$AUTHOR"),
  "status": $(json_str "$STATUS"),
  "risk_class": $(json_str "$RISK"),
  "created": $(json_str "$CREATED"),
  "last_update": $(json_str "$LAST_UPDATE"),
  "reviewers": $(json_str "$REVIEWERS"),
  "goal": $(json_str "$GOAL"),
  "risk_class_rationale": $(json_str "$RISK_RATIONALE"),
  "acceptance_criteria": $AC_ARRAY,
  "property_based_invariants": $INV_ARRAY,
  "definition_of_done": $DOD_ARRAY,
  "sections": {
    "has_goal":          $has_goal,
    "has_non_goals":     $has_nongoals,
    "has_acceptance":    $has_ac,
    "has_invariants":    $has_inv,
    "has_risk_rationale": $has_risk,
    "has_definition_of_done": $has_dod
  }
}
EOF
