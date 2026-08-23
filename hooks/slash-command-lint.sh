#!/usr/bin/env bash
# slash-command-lint.sh
# UserPromptSubmit hook + standalone scanner: валидация slash-команд.
#
# Две задачи:
#
# 1. Frontmatter. Каждая команда в .gigacode/commands/*.md обязана нести YAML-
#    frontmatter с непустым `description`: по нему рантайм показывает команду в
#    списке, а агент понимает, когда её звать. Команда без него просто теряется.
#
# 2. Защита от §5.4 bypass (класс уязвимости adversa2026bypass): если у команды
#    появляется больше N перечисленных вариантов / подкоманд, harness схлопывает
#    их в один generic approval prompt — одно «да» разрешает все варианты.
#
# v2 — исправлен счётчик вариантов. Заявлено в шапке всегда было «количество
# явно перечисленных вариантов» внутри блоков Options / Variants / Subcommands,
# а считались все буллеты markdown в файле. Обычная документированная команда
# легко набирает полсотни пунктов ни на что не влияющими списками: review.md
# держался на 46 при пороге блокировки 50. Поскольку хук висит на
# UserPromptSubmit, два лишних пункта в документации заблокировали бы ЛЮБОЙ
# промпт пользователя. Теперь считаются только перечисления в тех секциях, о
# которых и шла речь.
#
# Standalone-режим для quarterly review:
#   bash .gigacode/hooks/slash-command-lint.sh --scan-only

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

# Хук сканирует каталог команд по относительному пути: из подкаталога он его
# просто не находил и выходил с exit 0, то есть «нарушений нет».
cd_harness_root

COMMANDS_DIR=".gigacode/commands"
LIMIT_BLOCK=50
LIMIT_WARN=25

SCAN_ONLY=0
[[ "${1:-}" == "--scan-only" ]] && SCAN_ONLY=1

# В hook-режиме payload нужен только ради имени события в отказе. В standalone
# (--scan-only) stdin принадлежит вызывающему — читать его нельзя.
[[ "$SCAN_ONLY" -eq 0 ]] && hook_read_payload

# === STEP 1: prepare ===
if [[ ! -d "$COMMANDS_DIR" ]]; then
  exit 0
fi

# === STEP 2: scan ===
WARNINGS=()
FAILURES=()

# Считает буллеты внутри секций Options / Variants / Subcommands.
# Секция — от её заголовка до следующего заголовка того же или высшего уровня.
count_enumerated_variants() {
  awk '
    /^#+[[:space:]]*[Oo]ptions|^#+[[:space:]]*[Vv]ariants|^#+[[:space:]]*[Ss]ubcommands/ {
      in_section = 1; next
    }
    /^#+[[:space:]]/ { in_section = 0 }
    in_section && /^[[:space:]]{0,4}[-*][[:space:]]/ { n++ }
    END { print n+0 }
  ' "$1"
}

while IFS= read -r -d '' file; do
  name=$(basename "$file" .md)

  # --- frontmatter ---
  if [[ "$(head -1 "$file")" != "---" ]]; then
    FAILURES+=("$name: нет YAML-frontmatter (первая строка должна быть '---').")
  else
    desc=$(awk 'NR>1 && /^---[[:space:]]*$/ {exit} NR>1 && /^description:/ {
      sub(/^description:[[:space:]]*/, ""); print; exit
    }' "$file")
    if [[ -z "${desc// /}" ]]; then
      FAILURES+=("$name: frontmatter без непустого 'description' — команда не попадёт в список.")
    fi
  fi

  # --- перечисленные варианты ---
  variants=$(count_enumerated_variants "$file")
  variants=${variants:-0}

  # Count explicit "Options:" / "Variants:" / "Subcommands:" sections
  # `|| true` because grep returns 1 when no match found, which kills `set -e`.
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
    REASON=$(printf 'Slash-command lint per §5.4 PDLC v3.5. Findings: %s. Fix: добавь frontmatter с description, либо раздели команду на sub-skills / вынеси перечисления в policy-файлы.' "$(IFS='; '; echo "${FAILURES[*]}")")
    deny "$REASON"
  fi
fi

if [[ "$SCAN_ONLY" -eq 1 ]]; then
  echo "[slash-command-lint] OK — scanned $(find "$COMMANDS_DIR" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ') commands." >&2
fi
exit 0
