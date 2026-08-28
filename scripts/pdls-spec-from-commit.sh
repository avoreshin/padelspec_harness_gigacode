#!/usr/bin/env bash
# pdls-spec-from-commit.sh — детерминированные guardrails для /spec-from-commit.
#
# Origin: портирован из workspace-репо (SDD 20260827-pdls-spec-from-commit, R2).
#
# Агентная генерация (resolve→surface→explore→synthesize→review, стратегия S2)
# живёт в .gigacode/commands/spec-from-commit.md. Этот скрипт — детерминированная
# опора БЕЗ LLM: нормализовать commit-ссылки в SHA, выдать «change surface» как грунт
# для синтеза, провалидировать заполненный SDD против sdd.schema.json, сверить
# traceability (коммиты + anchor'ы) с текущим состоянием репозитория.
#
# Sibling .gigacode/scripts/pdls-spec-seed.sh (модуль → capability-спека). Здесь источник —
# git-коммиты, целевой шаблон — .gigacode/templates/SDD-template.md.
#
# Подкоманды:
#   resolve <ref|url> [...]  нормализовать commit ref/URL → полный SHA (по строке)
#   task    <ref|url> [...]  извлечь номер задачи из сообщений коммитов (Jira KEY-123 / #123)
#   surface <ref|url> [...]  детерминированный change surface (файлы, сообщения, stat)
#   validate <sdd.md>        валидировать против sdd.schema.json (через validate-schemas.sh)
#   verify   <sdd.md>        сверить traceability: "> commit: <sha>" резолвятся, anchor'ы не дрейфят
#
# Exit-codes:
#   0 — ok
#   1 — validation failed / drift / unresolved commit / no traceability
#   2 — usage / file not found
#
# Идемпотентен, без сетевых вызовов, read-only по отношению к коду и истории.

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

usage() {
  cat >&2 <<EOF
usage: pdls-spec-from-commit.sh <command> [args]
  resolve <ref|url> [...]  normalize commit ref/URL to full SHA (one per line)
  task    <ref|url> [...]  extract task id from commit messages (Jira KEY-123 / #123)
  surface <ref|url> [...]  deterministic change surface (files, messages, stat)
  validate <sdd.md>        validate against sdd.schema.json
  verify   <sdd.md>        check traceability commits + inline anchors against repo
EOF
  exit 2
}

# normalize_ref — из GitHub-URL вида .../commit/<sha> или .../commits/<sha> вытащить
# <sha>; голый ref/hash оставить как есть. Обрезать query/fragment (#…, ?…).
normalize_ref() {
  local raw="$1" ref
  ref="$(printf '%s' "$raw" | sed -E 's#^https?://[^[:space:]]*/commits?/##')"
  ref="${ref%%[#?]*}"
  ref="${ref%/}"
  printf '%s' "$ref"
}

# resolve_one — normalize + git rev-parse --verify. Печатает полный SHA или пусто (+rc).
resolve_one() {
  local ref; ref="$(normalize_ref "$1")"
  [ -z "$ref" ] && return 1
  git rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null
}

cmd_resolve() {
  [ $# -lt 1 ] && usage
  local raw sha rc=0
  for raw in "$@"; do
    if sha="$(resolve_one "$raw")" && [ -n "$sha" ]; then
      printf '%s\n' "$sha"
    else
      echo "error: cannot resolve commit: $raw" >&2
      rc=2
    fi
  done
  exit $rc
}

# cmd_task — извлечь номер задачи из сообщений (subject+body) коммитов.
# Распознаёт Jira-подобные ключи (KEY-123, ≥2 буквы) и GitHub-issue (#123).
# Нормализует в filename-safe токены: KEY-123 → key-123, #123 → issue-123.
# Печатает уникальные токены (по одному на строку), сохраняя порядок появления.
# Exit 0 — найдено; 1 — ни одного (команда спросит номер у пользователя); 2 — resolve.
cmd_task() {
  [ $# -lt 1 ] && usage
  local raw sha msgs=""
  for raw in "$@"; do
    if ! sha="$(resolve_one "$raw")" || [ -z "$sha" ]; then
      echo "error: cannot resolve commit: $raw" >&2
      exit 2
    fi
    msgs+="$(git show -s --format='%s%n%b' "$sha")"$'\n'
  done

  local found
  found="$(printf '%s\n' "$msgs" \
    | grep -oE '[A-Z]{2,}-[0-9]+|#[0-9]+' \
    | awk '{ if ($0 ~ /^#/) { sub(/^#/, "issue-"); print } else { print tolower($0) } }' \
    | awk '!seen[$0]++')"

  if [ -z "$found" ]; then
    echo "error: no task id in commit message(s) (ожидается Jira KEY-123 или #123)" >&2
    exit 1
  fi
  printf '%s\n' "$found"
  exit 0
}

cmd_surface() {
  [ $# -lt 1 ] && usage
  local raw sha
  for raw in "$@"; do
    if ! sha="$(resolve_one "$raw")" || [ -z "$sha" ]; then
      echo "error: cannot resolve commit: $raw" >&2
      exit 2
    fi
    echo "=== commit: $sha ==="
    git show --no-patch --format='author: %an%ndate:   %ad%nsubject: %s%n%n%b' "$sha"
    echo "--- files changed ---"
    git diff-tree --no-commit-id --name-only -r "$sha"
    echo "--- diffstat ---"
    git show --stat --format='' "$sha" | sed '/^$/d'
    echo ""
  done
  exit 0
}

cmd_validate() {
  local file="${1:-}"
  [ -z "$file" ] && usage
  [ -f "$file" ] || { echo "error: file not found: $file" >&2; exit 2; }

  if bash .gigacode/scripts/validate-schemas.sh validate sdd "$file" >/dev/null 2>&1; then
    echo "valid: $file conforms to sdd schema"
    exit 0
  fi
  echo "invalid: $file does NOT conform to sdd schema" >&2
  exit 1
}

cmd_verify() {
  local file="${1:-}"
  [ -z "$file" ] && usage
  [ -f "$file" ] || { echo "error: file not found: $file" >&2; exit 2; }

  local total=0 bad=0

  # (a) traceability commits: "> commit: <sha>[ — subject]"
  local sha
  while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    total=$((total + 1))
    if ! git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1; then
      echo "verify: traceability commit does not resolve: $sha" >&2
      bad=$((bad + 1))
    fi
  done < <(grep -oE '> commit:[[:space:]]*[0-9A-Za-z]+' "$file" | sed -E 's/^> commit:[[:space:]]*//')

  # (b) inline anchors: "anchor: <path>:<line>" (same drift check as pdls-spec-seed)
  local a path line n
  while IFS= read -r a; do
    total=$((total + 1))
    path="${a%:*}"
    line="${a##*:}"
    if [ ! -f "$path" ]; then
      echo "drift: anchor target missing: $path" >&2
      bad=$((bad + 1))
      continue
    fi
    n="$(wc -l < "$path" | tr -d ' ')"
    if [ "$line" -gt "$n" ]; then
      echo "drift: $path has $n lines, anchor points to :$line" >&2
      bad=$((bad + 1))
    fi
  done < <(grep -oE 'anchor:[[:space:]]*[^ )]+:[0-9]+' "$file" | sed -E 's/^anchor:[[:space:]]*//')

  if [ "$total" -eq 0 ]; then
    echo "error: no traceability found in $file (нужен '> commit: <sha>' или 'anchor: <path>:<line>')" >&2
    exit 1
  fi
  if [ "$bad" -gt 0 ]; then
    echo "verify: $bad/$total traceability refs failed" >&2
    exit 1
  fi
  echo "verify: all $total traceability refs resolve"
  exit 0
}

[ $# -lt 1 ] && usage
cmd="$1"; shift || true

case "$cmd" in
  resolve)  cmd_resolve "$@" ;;
  task)     cmd_task "$@" ;;
  surface)  cmd_surface "$@" ;;
  validate) cmd_validate "${1:-}" ;;
  verify)   cmd_verify "${1:-}" ;;
  -h|--help|help) usage ;;
  *) echo "error: unknown command: $cmd" >&2; usage ;;
esac
