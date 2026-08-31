#!/usr/bin/env bash
# sdd-coverage-gate.sh — PreToolUse hook for Bash.
#
# Гейт acceptance criteria цикла тестирования: тест-модель релиза не считается
# готовой, пока у каждой story нет approved-SDD и пока каждый его `AC-*` не
# покрыт кейсом.
#
# ЗАЧЕМ. Цикл сверял сценарии с тест-моделью, а саму тест-модель — ни с чем: её
# порождал агент из описаний в трекере, и «человек потом поправит» было
# единственной гарантией. Цикл честно реализовывал модель, которая могла быть
# неверной, и ни один гейт этого не видел. Критерии берутся из того же
# артефакта, что и в dev-цикле, — SDD в `docs/sdd/` (§2.5 PDLC), — и читаются
# тем же `extract-sdd-frontmatter.sh`, которым SDD валидируются везде ещё.
#
# ТОЛЬКО ПОЛНЫЙ ЦИКЛ. Гейт висит не на командах, а на событии фазы:
# `emit-phase-event.sh --loop testing …`. Такие события пишет только
# оркестратор `/test-workflow`; `/generate-test-cases`, `/generate-autotests` и
# `/review-autotests`, запущенные руками, их не эмитят вовсе — и потому ведут
# себя ровно как раньше, без единой новой проверки. Это то же разделение, что и
# у остального цикла: переходы принадлежат оркестратору, а не командам.
#
# ДВЕ ТОЧКИ СРАБАТЫВАНИЯ:
#   1. выход из фазы `model` со статусом `pass` — главная. Дальше по модели
#      генерируются сценарии, и непокрытый критерий превращается в отсутствующий
#      автотест, которого никто уже не хватится.
#   2. переход в `done` — последний рубеж: релиз не закрывается как
#      протестированный, пока критерий не покрыт.
#
# Contract:
#   - stdin: JSON event with .tool_input.command
#   - вердикт НЕ читается из файла, а пересчитывается: тест-модель и SDD
#     меняются между фазами, а сверка детерминированная и offline
#   - BLOCK (есть blocker'ы) → {"decision":"deny", …} + exit 2
#   - REQUEST CHANGES (только major) → предупреждение в stderr, exit 0
#   - APPROVE, нет тест-модели, нет python3 → exit 0
#
# Почему блокирует только BLOCK. Blocker — установленный факт: у story нет
# критериев, критерий не покрыт, кейс ссылается на несуществующий AC. Major —
# «кейс не сослан ни на один AC»: это дисциплина ссылок, и гейт на ней был бы
# шумным на первой же миграции старой тест-модели.
#
# Снять: /harness hooks disable sdd-coverage-gate (R2, обоснование — в свод по
# релизу либо в commit message).

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

printf '%s' "$COMMAND" | grep -q 'emit-phase-event\.sh' || exit 0

# Аргументы события. `|| true` не косметика: под `set -o pipefail` из common.sh
# конвейер с безрезультатным sed возвращает 1, и присваивание убило бы хук с
# кодом 1 — для рантайма это «хук не сработал», то есть тихий пропуск политики.
ARGS="$(printf '%s' "$COMMAND" \
  | sed -nE 's#.*emit-phase-event\.sh[[:space:]]+(.*)#\1#p' | head -1 || true)"
[ -n "$ARGS" ] || exit 0

# Событие dev-цикла поля `--loop` не несёт вовсе — и не должно сюда попадать.
case "$ARGS" in
  *"--loop testing"*) ;;
  *) exit 0 ;;
esac

REST="${ARGS#*--loop testing}"
# set -f: без него токен вида `*` из reason раскрылся бы в имена файлов.
set -f
# shellcheck disable=SC2086
set -- $REST
set +f
RELEASE="${1:-}"
FROM="${2:-}"
TO="${3:-}"
STATUS="${4:-}"

[ -n "$RELEASE" ] || exit 0
[ "$STATUS" = "pass" ] || exit 0

# Только продвижение вперёд. `iterate`/`fail` уже отработаны выше проверкой
# статуса; повтор фазы model блокировать бессмысленно — её как раз и чинят.
case "${FROM}|${TO}" in
  model\|*) ;;
  *\|done) ;;
  *) exit 0 ;;
esac

COVERAGE="${BASH_SOURCE[0]%/*}/../scripts/sdd-testcoverage.py"
[ -f "$COVERAGE" ] || COVERAGE=".gigacode/scripts/sdd-testcoverage.py"
[ -f "$COVERAGE" ] || COVERAGE="$(harness_root)/.gigacode/scripts/sdd-testcoverage.py"
[ -f "$COVERAGE" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

# Присваивание из подстановки команд возвращает код команды, а хук наследует
# `set -e`: `RC=$?` следующей строкой не выполнится вовсе — скрипт умрёт на
# самом присваивании, а блокировкой рантайм считает только exit 2. Ровно этим в
# v0.9.8 был сломан Stop-гейт.
RC=0
OUTPUT="$(python3 "$COVERAGE" "$RELEASE" --project . 2>&1)" || RC=$?

# rc=2 — сверка не смогла разобрать вход (нет тест-модели, нет экстрактора).
# Это не «критерии не покрыты», и вызываемая команда скажет то же внятнее.
[ "$RC" = "2" ] && exit 0
[ "$RC" = "0" ] && exit 0

VERDICT="$(printf '%s' "$OUTPUT" | sed -nE 's/^VERDICT:[[:space:]]*(.*)$/\1/p' | head -1)"
FINDINGS="$(printf '%s' "$OUTPUT" | grep -E '^- \[' | head -5 || true)"

if [ "$VERDICT" != "BLOCK" ]; then
  printf '%s\n' "[sdd-coverage-gate] покрытие: $VERDICT ($RELEASE) — не блокирую, но ссылки на критерии неполны." >&2
  printf '%s\n' "$FINDINGS" >&2
  exit 0
fi

WHERE="фаза model не пройдена"
[ "$TO" = "done" ] && WHERE="цикл не закрывается"

deny "$WHERE: acceptance criteria релиза $RELEASE не сошлись с SDD.

$FINDINGS

Тест-модель — это то, из чего дальше генерируются сценарии. Непокрытый AC
превращается в отсутствующий автотест, которого потом никто не хватится, а
story без SDD означает, что критериев не зафиксировано вовсе.

Полный отчёт:       python3 .gigacode/scripts/sdd-testcoverage.py $RELEASE --project .
Шаблон SDD:         .gigacode/templates/SDD-template.md
Связь со story:     строка \`**Story**\` в Metadata-таблице SDD
Снять гейт осознанно: /harness hooks disable sdd-coverage-gate"
