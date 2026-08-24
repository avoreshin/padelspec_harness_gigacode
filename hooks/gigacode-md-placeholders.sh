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
#   - warn (exit 0) by default
#   - GIGACODE_MD_STRICT=1 → тот же отчёт, но ненулевым кодом (exit 2)
#   - skip silently when .gigacode/GIGACODE.md doesn't exist
#
# ВАЖНО про strict. SessionStart не входит в список блокирующих событий ни в
# GigaCode, ни в GigaCode / GigaCode: остановить старт сессии хук на этом
# событии не может в принципе. GIGACODE_MD_STRICT=1 поэтому не «блокирует
# сессию», а лишь делает отказ заметным — ненулевой код виден в hook-докторе и
# в CI, где этот же скрипт запускают напрямую. Прежняя формулировка обещала
# блокировку, которой рантайм не выполнял.

set -euo pipefail

# Хук запускается с cwd рабочей директории агента, которая не обязана быть
# корнем репозитория. Без резолва относительный путь к GIGACODE.md не нашёлся бы
# и хук молча выходил бы с exit 0 — то есть «плейсхолдеров нет».
if _root="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$_root" ]]; then
  cd "$_root"
fi

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
  echo "GIGACODE_MD_STRICT=1: незаполненные плейсхолдеры считаются ошибкой. Заполни их или сними флаг." >&2
  exit 2
fi

exit 0
