#!/usr/bin/env bash
# pdls-spec-seed.sh — детерминированные guardrails для /spec-seed.
#
# Source SDD: docs/sdd/20260821-pdls-spec-seed-spike.md (R2 spike, approved).
#
# Агентная генерация (explore→synthesize→review, стратегия S2) живёт в
# .gigacode/commands/spec-seed.md. Этот скрипт — детерминированная опора
# БЕЗ LLM (INV-1/INV-3): создать каталог кандидатов, провалидировать кандидат
# против capability-spec.schema.json, сверить inline-anchor'ы с текущим кодом.
#
# Подкоманды:
#   scaffold                 создать .kb/specs/ и напечатать путь
#   validate <candidate.md>  валидировать против capability-spec.schema.json
#   verify   <candidate.md>  сверить anchor'ы "anchor: <path>:<line>" с кодом (дрейф)
#
# Exit-codes:
#   0 — ok
#   1 — validation failed / drift detected / no anchors
#   2 — usage / file not found
#
# Идемпотентен, без сетевых вызовов, read-only по отношению к коду.

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

KB_DIR="${PDLS_KB_DIR:-.kb/specs}"

usage() {
  cat >&2 <<EOF
usage: pdls-spec-seed.sh <command> [args]
  scaffold                 create \$PDLS_KB_DIR (default .kb/specs) and print path
  discover <repo-dir>      decompose repo into capability candidates (by package)
  validate <candidate.md>  validate against capability-spec.schema.json
  verify   <candidate.md>  check inline anchors (anchor: <path>:<line>) against code
  manifest [specs-dir]     build manifest index of .kb/specs/*.md (default \$PDLS_KB_DIR)
EOF
  exit 2
}

cmd_scaffold() {
  mkdir -p "$KB_DIR"
  printf '%s\n' "$KB_DIR"
}

cmd_validate() {
  local file="${1:-}"
  [ -z "$file" ] && usage
  [ -f "$file" ] || { echo "error: file not found: $file" >&2; exit 2; }

  if bash .gigacode/scripts/validate-schemas.sh validate capability-spec "$file" >/dev/null 2>&1; then
    echo "valid: $file conforms to capability-spec"
    exit 0
  fi
  echo "invalid: $file does NOT conform to capability-spec" >&2
  exit 1
}

cmd_verify() {
  local file="${1:-}"
  [ -z "$file" ] && usage
  [ -f "$file" ] || { echo "error: file not found: $file" >&2; exit 2; }

  local total=0 drift=0 a path line n
  while IFS= read -r a; do
    total=$((total + 1))
    path="${a%:*}"
    line="${a##*:}"
    if [ ! -f "$path" ]; then
      echo "drift: anchor target missing: $path" >&2
      drift=$((drift + 1))
      continue
    fi
    n="$(wc -l < "$path" | tr -d ' ')"
    if [ "$line" -gt "$n" ]; then
      echo "drift: $path has $n lines, anchor points to :$line" >&2
      drift=$((drift + 1))
    fi
  done < <(grep -oE 'anchor:[[:space:]]*[^ )]+:[0-9]+' "$file" | sed -E 's/^anchor:[[:space:]]*//')

  if [ "$total" -eq 0 ]; then
    echo "error: no anchors found in $file (INV-2: каждое REQ должно быть заякорено)" >&2
    exit 1
  fi
  if [ "$drift" -gt 0 ]; then
    echo "verify: $drift/$total anchors drifted" >&2
    exit 1
  fi
  echo "verify: all $total anchors resolve"
  exit 0
}

# discover — детерминированная декомпозиция репо на capability-кандидаты по
# package-декларации (последний сегмент package → kebab-имя capability). Без LLM.
# Агентный synthesize затем строит спеку на каждый кандидат.
cmd_discover() {
  local path="${1:-}"
  [ -z "$path" ] && usage
  [ -d "$path" ] || { echo "error: not a directory: $path" >&2; exit 2; }

  # Каталоги сборки и вендоринга исключаются до чтения файлов. Без этого
  # target/generated-sources попадал в декомпозицию наравне с исходниками:
  # сгенерированные классы объявляют те же package, поэтому в предложении
  # появлялись capability-кандидаты, которых в коде проекта нет.
  local files
  files="$(find "$path" \
    \( -type d \( -name target -o -name build -o -name out -o -name bin \
                 -o -name .git -o -name node_modules -o -name .idea -o -name .gradle \) -prune \) -o \
    -type f \( -name '*.java' -o -name '*.kt' \) -print 2>/dev/null | sort)"
  [ -z "$files" ] && { echo "error: no .java/.kt sources under $path" >&2; exit 1; }

  # Потолок на размер обхода. Отказ, а не молчаливое усечение: усечённая
  # декомпозиция выглядит как полная и уводит /spec-seed на неполный список
  # capability. Типичная причина срабатывания — discover запущен не на модуле,
  # а на каталоге, который случайно содержит весь монорепозиторий.
  local file_count; file_count="$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
  if [ "$file_count" -gt "${PDLS_DISCOVER_MAX_FILES:-5000}" ]; then
    echo "error: под $path нашлось $file_count исходников — больше потолка ${PDLS_DISCOVER_MAX_FILES:-5000}. Укажи конкретный модуль вместо корня, либо подними потолок переменной PDLS_DISCOVER_MAX_FILES, если такой объём осознан." >&2
    exit 1
  fi

  local tmp; tmp="$(mktemp)"
  local f pkg seg cap
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    pkg="$(grep -m1 -E '^package ' "$f" | sed -E 's/^package[[:space:]]+//; s/[;[:space:]]*$//')"
    seg="${pkg##*.}"
    [ -z "$seg" ] && seg="root"
    cap="$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
    printf '%s\t%s\n' "$cap" "$f" >> "$tmp"
  done <<< "$files"

  echo "# decomposition proposal: $path"
  local caps c cnt n=0
  caps="$(cut -f1 "$tmp" | sort -u)"
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    n=$((n + 1))
    cnt="$(awk -F'\t' -v c="$c" '$1==c{k++} END{print k+0}' "$tmp")"
    printf 'capability: %s (%s files)\n' "$c" "$cnt"
    awk -F'\t' -v c="$c" '$1==c{print "  - "$2}' "$tmp"
  done <<< "$caps"
  rm -f "$tmp"
  printf 'total: %s capabilities\n' "$n"
  exit 0
}

# manifest — детерминированный индекс .kb/specs/*.md: таблица (capability, status,
# #REQ) + секция Dependencies (bullets из "## Dependencies" каждой спеки, прозой).
# Печатает в stdout И пишет <specs-dir>/manifest.md. Без LLM.
cmd_manifest() {
  local dir="${1:-$KB_DIR}"
  [ -d "$dir" ] || { echo "error: not a directory: $dir" >&2; exit 2; }

  local specs
  specs="$(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'manifest.md' 2>/dev/null | sort)"
  [ -z "$specs" ] && { echo "error: no spec .md files in $dir" >&2; exit 1; }

  # Индекс кладётся внутрь каталога спек, рядом с тем, что индексирует.
  # Раньше он писался в родительский каталог: путь наружу означал, что при
  # manifest на произвольном каталоге файл появлялся там, где его никто не
  # ждёт. Собственный вывод не становится входом при повторном прогоне —
  # manifest.md исключён из find выше, и это исключение теперь обязательно.
  local out; out="$dir/manifest.md"
  local s cap status reqs deps any=0
  {
    echo "# Knowledge Base Manifest"
    echo
    echo "> Сгенерирован pdls-spec-seed.sh manifest из $dir · generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "| Capability | Status | REQ | Spec |"
    echo "| --- | --- | --- | --- |"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      cap="$(grep -m1 -E '^\|[[:space:]]*capability[[:space:]]*\|' "$s" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
      [ -z "$cap" ] && cap="$(basename "$s" .md)"
      status="$(grep -m1 -E '^\|[[:space:]]*status[[:space:]]*\|' "$s" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
      [ -z "$status" ] && status="?"
      reqs="$(grep -cE '^### REQ-[0-9]+' "$s")"
      printf '| %s | %s | %s | %s |\n' "$cap" "$status" "$reqs" "$(basename "$s")"
    done <<< "$specs"
    echo
    echo "## Dependencies"
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      cap="$(grep -m1 -E '^\|[[:space:]]*capability[[:space:]]*\|' "$s" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')"
      [ -z "$cap" ] && cap="$(basename "$s" .md)"
      deps="$(awk '/^## Dependencies/{f=1;next} /^## /{f=0} f && /^- /{print}' "$s")"
      if [ -n "$deps" ]; then
        any=1
        echo "### $cap"
        printf '%s\n' "$deps"
      fi
    done <<< "$specs"
    [ "$any" -eq 0 ] && echo "_нет объявленных зависимостей_"
  } | tee "$out"
  exit 0
}

[ $# -lt 1 ] && usage
cmd="$1"; shift || true

case "$cmd" in
  scaffold) cmd_scaffold ;;
  discover) cmd_discover "${1:-}" ;;
  validate) cmd_validate "${1:-}" ;;
  verify)   cmd_verify "${1:-}" ;;
  manifest) cmd_manifest "${1:-}" ;;
  -h|--help|help) usage ;;
  *) echo "error: unknown command: $cmd" >&2; usage ;;
esac
