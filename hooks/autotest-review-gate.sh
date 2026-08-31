#!/usr/bin/env bash
# autotest-review-gate.sh — PreToolUse hook for Bash.
#
# Гейт сгенерированных автотестов: сценарии, расходящиеся с тест-моделью,
# нельзя ни объявить готовыми, ни выгрузить в TMS.
#
# Зачем гейт, если шаг ревью и так прописан в /generate-autotests. Потому что
# прописанный шаг — вероятностное соблюдение (§2.6 PDLC): он выполняется, пока
# агент помнит инструкцию.
#
# Две точки срабатывания, и первая — главная:
#
#   1. `test-edit-window.sh close` — конец генерации. Автотест, проверяющий не
#      то, что просила тест-модель, бесполезен сам по себе, а не только в момент
#      выгрузки: он зеленеет и создаёт видимость покрытия. Пока сверка даёт
#      BLOCK, окно правки тестов не закрывается — цикл не закончен.
#   2. `export-testcases-xml.py` — последний рубеж. Кейс с таким автотестом
#      уезжает в Zephyr как покрытый автоматизацией, и дальше на него полагаются.
#
# Contract:
#   - stdin: JSON event with .tool_input.command
#   - вердикт НЕ читается из файла, а пересчитывается: записанный вердикт
#     протухает молча после любой перегенерации сценариев, а сверка
#     детерминированная, offline и стоит доли секунды
#   - BLOCK (есть blocker'ы) → {"decision":"block", …} + exit 2
#   - REQUEST CHANGES (только major/minor) → предупреждение в stderr, exit 0
#   - APPROVE, нечего сверять, нет python3 → exit 0
#
# Почему блокирует только BLOCK. Blocker означает «сценарий проверяет не то» —
# это установленный факт: канал ушёл, ожидание инвертировано, проверки нет
# вовсе. Major означает «проверяется, возможно, не всё» (в сценарии нет объекта,
# названного в тест-модели), и его закрытие часто требует шага, которого в
# проекте ещё нет. Гейт, блокирующий и на major, был бы неснимаемым — и его
# сняли бы целиком, вместе с защитой от blocker'ов.
#
# Окно правки тестов на фазе Test PDLC-loop'а гейт не трогает: он смотрит на
# причину, с которой окно открывали, и вмешивается только в генерацию
# автотестов. Иначе он ломал бы TDD в проекте, где тестовой модели нет вовсе.
#
# Снять гейт: /harness hooks disable autotest-review-gate (R2, обоснование — в
# commit message либо в evidence bundle).

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

MODE=""
TARGETS=""

if printf '%s' "$COMMAND" | grep -q 'export-testcases-xml\.py'; then
  MODE="export"
  # Аргумент выгрузки: первый токен после имени скрипта, не начинающийся с дефиса.
  TARGETS="$(printf '%s' "$COMMAND" \
    | sed -nE 's#.*export-testcases-xml\.py[[:space:]]+([^[:space:];|&]+).*#\1#p' | head -1)"
  case "$TARGETS" in
    ""|-*) exit 0 ;;   # цель не разобрана — блокировать наугад нельзя
  esac
elif printf '%s' "$COMMAND" | grep -qE 'test-edit-window\.sh[[:space:]]+close'; then
  MODE="close"
  # Зачем открывали окно — записано в маркере. Фаза Test PDLC-loop'а открывает
  # его со своей причиной, и в неё гейт не вмешивается.
  MARKER=".gigacode/.cost/test-edit-allowed"
  [ -f "$MARKER" ] || exit 0
  REASON="$(cut -f2- < "$MARKER" 2>/dev/null || true)"
  printf '%s' "$REASON" | grep -qi 'автотест' || exit 0
  # Ключ релиза из причины; нет ключа — сверяются все тест-модели, у которых
  # есть сгенерированные сценарии. Пропустить проверку молча здесь нельзя:
  # причина пишется человеком и легко теряет ключ.
  # `|| true` не косметика: под `set -o pipefail` из common.sh конвейер с
  # безрезультатным grep возвращает 1, и присваивание убило бы хук с кодом 1 —
  # для рантайма это «хук не сработал», то есть тихий пропуск политики.
  TARGETS="$(printf '%s' "$REASON" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -3 || true)"
  if [ -z "$TARGETS" ]; then
    TARGETS="$(ls docs/testcases/*.yaml 2>/dev/null | head -5 || true)"
  fi
  [ -n "$TARGETS" ] || exit 0
else
  exit 0
fi

# Скрипт сверки ищется сначала рядом с самим хуком: хук и скрипты обвязки едут
# вместе — и в `.gigacode/` установленного проекта, и в каталоге расширения, где
# путь `.gigacode/scripts` не существует вовсе. Поиск от текущего каталога —
# запасной путь, а не основной: команда запускается из корня проекта не всегда.
REVIEW="${BASH_SOURCE[0]%/*}/../scripts/autotest-review.py"
[ -f "$REVIEW" ] || REVIEW=".gigacode/scripts/autotest-review.py"
[ -f "$REVIEW" ] || REVIEW="$(harness_root)/.gigacode/scripts/autotest-review.py"
[ -f "$REVIEW" ] || exit 0

# Без python3 сверять нечем. Это не «разрешить»: без него не работает и сама
# выгрузка — тот же python3 её и выполняет, — поэтому гейт молча уступает.
command -v python3 >/dev/null 2>&1 || exit 0

BLOCKED=""
SUMMARY=""
SOFT=""

for TARGET in $TARGETS; do
  # Присваивание из подстановки команд возвращает код команды, а хук наследует
  # `set -e` из common.sh: `RC=$?` следующей строкой не выполнится вовсе — скрипт
  # умрёт на самом присваивании с кодом ревью, а блокировкой рантайм считает
  # только exit 2. Ровно этим в v0.9.8 был сломан Stop-гейт.
  RC=0
  OUTPUT="$(python3 "$REVIEW" "$TARGET" --project . 2>&1)" || RC=$?

  # rc=2 — ревью не смогло разобрать вход (нет тест-модели, не проект
  # автотестов). Это не «сценарии проверяют не то», и вызываемая команда скажет
  # то же внятнее.
  [ "$RC" = "2" ] && continue
  [ "$RC" = "0" ] && continue

  VERDICT="$(printf '%s' "$OUTPUT" | sed -nE 's/^VERDICT:[[:space:]]*(.*)$/\1/p' | head -1)"
  FINDINGS="$(printf '%s' "$OUTPUT" | grep -E '^- \[' | head -5)"
  if [ "$VERDICT" = "BLOCK" ]; then
    BLOCKED="${BLOCKED:+$BLOCKED }$TARGET"
    SUMMARY="${SUMMARY}${SUMMARY:+
}$FINDINGS"
  else
    SOFT="${SOFT:+$SOFT }$TARGET"
  fi
done

if [ -z "$BLOCKED" ]; then
  if [ -n "$SOFT" ]; then
    printf '%s\n' "[autotest-review-gate] ревью: REQUEST CHANGES ($SOFT) — не блокирую, но находки не разобраны." >&2
    printf '%s\n' "Разбор: /review-autotests $SOFT" >&2
  fi
  exit 0
fi

if [ "$MODE" = "close" ]; then
  block "генерация автотестов не закончена: ревью даёт BLOCK по $BLOCKED.
Сценарии проверяют не то, что просила тест-модель, — такой автотест зеленеет и
создаёт видимость покрытия.

$SUMMARY

Окно правки тестов оставлено открытым намеренно: цикл не закончен.
Починить механическое:  /review-autotests $BLOCKED --fix
Полный отчёт:           python3 .gigacode/scripts/autotest-review.py $BLOCKED --project .
Снять гейт осознанно:   /harness hooks disable autotest-review-gate"
fi

block "выгрузка в TMS заблокирована: ревью автотестов даёт BLOCK по $BLOCKED.
Сценарии расходятся с тест-моделью, а в Zephyr они уедут как покрытые автоматизацией.

$SUMMARY

Разобрать и починить:  /review-autotests $BLOCKED --fix
Полный отчёт:          python3 .gigacode/scripts/autotest-review.py $BLOCKED --project .
Снять гейт осознанно:  /harness hooks disable autotest-review-gate"
