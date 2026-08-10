#!/usr/bin/env bash
# slash-command-lint.sh
# UserPromptSubmit hook + standalone scanner: защита от §5.4 bypass.
#
# Класс уязвимости (adversa2026bypass): если у slash-команды появляется
# больше N подкоманд / вариантов / условных веток, harness схлопывает их
# в один generic approval prompt. Один yes — все варианты разрешены.
#
# Этот hook:
#   1. Сканирует .gigacode/commands/*.md.
#   2. Для каждой команды считает:
#       - количество "Options:" / "Variants:" / "Subcommands:" блоков,
#       - количество явно перечисленных вариантов (line starting with `-`/`*`),
#       - длину файла (>500 строк = подозрительно для одной команды).
#   3. Если число вариантов > 50 — block.
#   4. Если 25–50 — warning в stderr.
#   5. Можно запускать standalone (без stdin) для quarterly review:
#        bash .gigacode/hooks/slash-command-lint.sh --scan-only

set -euo pipefail

COMMANDS_DIR=".gigacode/commands"
LIMIT_BLOCK=50
LIMIT_WARN=25

SCAN_ONLY=0
[[ "${1:-}" == "--scan-only" ]] && SCAN_ONLY=1

# === STEP 1: prepare ===
if [[ ! -d "$COMMANDS_DIR" ]]; then
  exit 0
fi

# === STEP 2: scan ===
WARNINGS=()
FAILURES=()

while IFS= read -r -d '' file; do
  name=$(basename "$file" .md)

  # Count bullet-style variants (lines starting with - or * at column 0–4)
  # `|| true` because grep returns 1 when no match found, which kills `set -e`.
  variants=$(grep -cE '^[[:space:]]{0,4}[-*][[:space:]]' "$file" 2>/dev/null || true)
  variants=${variants:-0}

  # Count explicit "Options:" / "Variants:" / "Subcommands:" sections
  section_count=$(grep -cEi '^#+[[:space:]]*(options|variants|subcommands)' "$file" 2>/dev/null || true)
  section_count=${section_count:-0}

  # File length
  lines=$(wc -l < "$file" | tr -d ' ')

  # Decision
  if [[ "$variants" -gt "$LIMIT_BLOCK" ]]; then
    FAILURES+=("$name: $variants enumerated variants (>$LIMIT_BLOCK). Approval bypass risk per §5.4.")
  elif [[ "$variants" -gt "$LIMIT_WARN" ]]; then
    WARNINGS+=("$name: $variants variants (warn >$LIMIT_WARN; block >$LIMIT_BLOCK).")
  fi

  if [[ "$lines" -gt 500 ]]; then
    WARNINGS+=("$name: ${lines} lines. Consider splitting into multiple commands.")
  fi

  if [[ "$section_count" -gt 5 ]]; then
    WARNINGS+=("$name: $section_count options/variants sections. Refactor toward sub-skills.")
  fi
done < <(find "$COMMANDS_DIR" -maxdepth 1 -name "*.md" -print0)

# === STEP 3: emit ===
if [[ ${#WARNINGS[@]} -gt 0 ]]; then
  for w in "${WARNINGS[@]}"; do
    echo "[slash-command-lint] WARN: $w" >&2
  done
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  if [[ "$SCAN_ONLY" -eq 1 ]]; then
    for f in "${FAILURES[@]}"; do
      echo "[slash-command-lint] FAIL: $f" >&2
    done
    exit 1
  else
    REASON=$(printf 'Slash-command bypass risk per §5.4 PDLC v3.5. Findings: %s. Refactor: split into sub-skills, or move enumerated options into structured policy files.' "$(IFS='; '; echo "${FAILURES[*]}")")
    cat >&2 <<EOF
{"decision": "block", "reason": "$REASON"}
EOF
    exit 2
  fi
fi

if [[ "$SCAN_ONLY" -eq 1 ]]; then
  echo "[slash-command-lint] OK — scanned $(ls "$COMMANDS_DIR"/*.md 2>/dev/null | wc -l) commands." >&2
fi
exit 0
