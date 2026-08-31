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
# ТРИ ТОЧКИ СРАБАТЫВАНИЯ — две про покрытие критериев, одна про готовность:
#   1. выход из фазы `model` со статусом `pass` — главная. Дальше по модели
#      генерируются сценарии, и непокрытый критерий превращается в отсутствующий
#      автотест, которого никто уже не хватится.
#   2. переход в `done` — последний рубеж: релиз не закрывается как
#      протестированный, пока критерий не покрыт.
#   3. переход в `run` — БАРЬЕР. Здесь проверяется не покрытие, а состояние
#      разработки: у каждой story SDD должен быть в статусе `implemented`.
#      Фазы model → review выводятся из критериев и кода не требуют, поэтому
#      идут параллельно разработке; прогон — единственная фаза, которой нужен
#      собранный продукт. Барьер потому один и стоит именно здесь.
#
#      Разработка при этом ведётся в другом репозитории, и evidence bundle
#      оттуда читать нельзя: он лежит по одному пути на репозиторий,
#      перезаписывается каждой задачей и обычно не под git. `implemented`
#      ставится человеком после фазы evidence и живёт в самом SDD — файле,
#      который тестировщик и так читает.
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
# Сверяем ПРЕФИКС, а не вхождение: emit-phase-event разбирает `--loop` только
# как первый аргумент, и та же строка внутри reason флагом не является.
case "$ARGS" in
  "--loop testing "*) ;;
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
CHECK=""
case "${FROM}|${TO}" in
  *\|run)  CHECK="readiness" ;;
  model\|*) CHECK="coverage" ;;
  *\|done) CHECK="coverage" ;;
  *) exit 0 ;;
esac

if [ "$CHECK" = "readiness" ]; then
  SCRIPT="${BASH_SOURCE[0]%/*}/../scripts/release-readiness.py"
  [ -f "$SCRIPT" ] || SCRIPT=".gigacode/scripts/release-readiness.py"
  [ -f "$SCRIPT" ] || SCRIPT="$(harness_root)/.gigacode/scripts/release-readiness.py"
else
  SCRIPT="${BASH_SOURCE[0]%/*}/../scripts/sdd-testcoverage.py"
  [ -f "$SCRIPT" ] || SCRIPT=".gigacode/scripts/sdd-testcoverage.py"
  [ -f "$SCRIPT" ] || SCRIPT="$(harness_root)/.gigacode/scripts/sdd-testcoverage.py"
fi
[ -f "$SCRIPT" ] || exit 0

command -v python3 >/dev/null 2>&1 || exit 0

# Присваивание из подстановки команд возвращает код команды, а хук наследует
# `set -e`: `RC=$?` следующей строкой не выполнится вовсе — скрипт умрёт на
# самом присваивании, а блокировкой рантайм считает только exit 2. Ровно этим в
# v0.9.8 был сломан Stop-гейт.
RC=0
OUTPUT="$(python3 "$SCRIPT" "$RELEASE" --project . 2>&1)" || RC=$?

# rc=2 — сверка не смогла разобрать вход (нет тест-модели, нет экстрактора).
# Это не «критерии не покрыты», и вызываемая команда скажет то же внятнее.
[ "$RC" = "2" ] && exit 0
[ "$RC" = "0" ] && exit 0

VERDICT="$(printf '%s' "$OUTPUT" | sed -nE 's/^VERDICT:[[:space:]]*(.*)$/\1/p' | head -1)"

if [ "$CHECK" = "readiness" ]; then
  # У готовности нет «мягкого» вердикта: либо разработка по story закрыта, либо
  # прогонять нечего. Смягчать здесь значило бы гонять сценарии по коду,
  # которого на стенде ещё нет, и разбирать падения не той природы.
  [ "$VERDICT" = "READY" ] && exit 0
  ROWS="$(printf '%s' "$OUTPUT" | sed -n '/^Прогон закрыт/,$p' | head -8 || true)"
  deny "барьер перед прогоном: разработка по релизу $RELEASE не закрыта.

$ROWS

Фазы model → review кода не требуют и потому шли параллельно разработке.
Прогон — единственная фаза, которой нужен собранный продукт, и до неё
статус каждой story обязан дойти до implemented: его ставит человек после
фазы evidence dev-цикла, в своём репозитории.

Отчёт:              python3 .gigacode/scripts/release-readiness.py $RELEASE --project .
Где искать SDD:     dev_repo / sdd_dir в docs/test-project-profile.md
Снять барьер:       /harness hooks disable sdd-coverage-gate"
fi

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
