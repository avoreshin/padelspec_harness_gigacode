#!/usr/bin/env bash
# extract-dora-frontmatter.sh — DORA baseline markdown → JSON.
#
# Source SDD: docs/sdd/20260520-schema-completeness.md (R1) — AC-2
# (SDD живёт в рабочем репозитории pdlc-harness-work, сюда не бэкпортился)
# Использование: scripts/extract-dora-frontmatter.sh <path-to-baseline.md>

set -u

[ $# -lt 1 ] && { echo '{"error":"usage: extract-dora-frontmatter.sh <file.md>"}' >&2; exit 2; }
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

# Read field from Metadata table: `| field | value |`
get_meta() {
  local field="$1"
  awk -F'|' -v f="$field" '
    BEGIN { IGNORECASE = 1 }
    NR == 1 { next }
    /^\| / && tolower($2) ~ ("^[ \t]*" tolower(f) "[ \t:]") {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$FILE"
}

# First "Среднее (median)" value under a given section heading
get_metric_median() {
  local heading="$1"  # e.g. "## 1." for Lead Time
  awk -F'|' -v h="$heading" '
    $0 ~ "^" h " " { in_sec = 1; next }
    /^## / && in_sec { exit }
    in_sec && /Среднее \(median\)/ {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
    in_sec && /MTTR \(median\)/ {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$FILE"
}

# DF: "Частота"; CFR: "CFR" value
get_metric_row() {
  local heading="$1"
  local label_pattern="$2"
  awk -F'|' -v h="$heading" -v lp="$label_pattern" '
    $0 ~ "^" h " " { in_sec = 1; next }
    /^## / && in_sec { exit }
    in_sec && $2 ~ lp {
      v = $3
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$FILE"
}

# ---------------------------------------------------------------------------
# Extract metadata
# ---------------------------------------------------------------------------

TEAM="$(get_meta team)"
REPOS_RAW="$(get_meta repos)"
WINDOW_RAW="$(get_meta measurement_window)"
WINDOW_DAYS_RAW="$(get_meta 'window')"
DATA_SOURCE="$(get_meta data_source)"
PRE_AI_RAW="$(get_meta 'pre-existing-ai-usage')"
MEASURED_BY="$(get_meta measured_by)"
CREATED="$(get_meta created)"
EXAMPLE_FILL_RAW="$(get_meta example_fill)"

# repos array: split by comma
REPOS_JSON='[]'
if [ -n "$REPOS_RAW" ]; then
  REPOS_JSON='['
  first=true
  IFS=',' read -ra _repos <<< "$REPOS_RAW"
  for r in "${_repos[@]}"; do
    r="$(printf '%s' "$r" | sed -E 's/^[ \t]+|[ \t]+$//g')"
    [ -z "$r" ] && continue
    if $first; then first=false; else REPOS_JSON+=','; fi
    REPOS_JSON+="$(json_str "$r")"
  done
  REPOS_JSON+=']'
fi

# Parse measurement_window: "from YYYY-MM-DD to YYYY-MM-DD" → from/to + days
WIN_FROM="$(printf '%s' "$WINDOW_RAW" | grep -oE 'from[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' | awk '{print $2}')"
WIN_TO="$(printf '%s' "$WINDOW_RAW" | grep -oE 'to[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}'   | awk '{print $2}')"
# Days: пытаемся вытащить число из строки `window: N days`. Если поле в формате `window` отсутствует — 0.
WIN_DAYS="$(printf '%s' "$WINDOW_DAYS_RAW" | grep -oE '[0-9]+' | head -1)"
# Fallback: parse "window: N days" из таблицы metadata-line напрямую
if [ -z "$WIN_DAYS" ]; then
  WIN_DAYS="$(awk -F'|' '
    /^\| window:[[:space:]]*[0-9]/ {
      gsub(/[^0-9]/, "", $2)
      print $2
      exit
    }
  ' "$FILE")"
fi
[ -z "$WIN_DAYS" ] && WIN_DAYS=0

# Normalize pre-existing-ai-usage to boolean
# Field is sometimes `| pre-existing-ai-usage: true | ... |` (in the key column)
PRE_AI="$(printf '%s\n%s' "$PRE_AI_RAW" "$(awk -F'|' '
  /^\| pre-existing-ai-usage:[[:space:]]*(true|false)/ {
    gsub(/.*pre-existing-ai-usage:[[:space:]]*/, "", $2)
    gsub(/[[:space:]]+$/, "", $2)
    print $2
    exit
  }
' "$FILE")" | grep -oE 'true|false' | head -1)"
# IMPORTANT: emit `null` (not `false`) when the field is missing — schema must
# reject absent flag. INV-1 anti-contamination depends on explicit presence.
[ -z "$PRE_AI" ] && PRE_AI="null"

# Metric extraction
LEAD_MEDIAN="$(get_metric_median '## 1\.')"
DF_VAL="$(get_metric_row '## 2\.' '[Чч]астота')"
CFR_VAL="$(get_metric_row '## 3\.' 'CFR')"
MTTR_MEDIAN="$(get_metric_median '## 4\.')"

# Raw data source — first non-empty bullet under "## Raw-data source"
RAW_SRC="$(awk '
  /^## Raw-data source/ { in_r = 1; next }
  /^## / && in_r        { exit }
  in_r && /^- / {
    sub(/^- /, "")
    print
    exit
  }
' "$FILE")"

# Has-section flags
has() { grep -qE "$1" "$FILE" && echo true || echo false; }

cat <<EOF
{
  "team": $(json_str "$TEAM"),
  "repos": $REPOS_JSON,
  "measurement_window": {
    "from": $(json_str "$WIN_FROM"),
    "to":   $(json_str "$WIN_TO"),
    "days": $WIN_DAYS
  },
  "lead_time":              { "median": $(json_str "$LEAD_MEDIAN") },
  "deployment_frequency":   { "value":  $(json_str "$DF_VAL") },
  "change_failure_rate":    { "value":  $(json_str "$CFR_VAL") },
  "mttr":                   { "median": $(json_str "$MTTR_MEDIAN") },
  "data_source":            $(json_str "$DATA_SOURCE"),
  "pre_existing_ai_usage":  $PRE_AI,
  "measured_by":            $(json_str "$MEASURED_BY"),
  "created":                $(json_str "$CREATED"),
  "raw_data_source":        $(json_str "$RAW_SRC"),
  "sections": {
    "has_lead_time":            $(has '^## 1\.'),
    "has_deployment_frequency": $(has '^## 2\.'),
    "has_change_failure_rate":  $(has '^## 3\.'),
    "has_mttr":                 $(has '^## 4\.'),
    "has_raw_data_source":      $(has '^## Raw-data source')
  }
}
EOF
