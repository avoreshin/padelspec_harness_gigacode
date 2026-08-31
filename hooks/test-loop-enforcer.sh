#!/usr/bin/env bash
# test-loop-enforcer.sh — Stop hook для цикла тестирования.
#
# Аналог evidence-bundle-enforcer, но для другого процесса: там задача не
# закрыта без evidence bundle, здесь релиз не закрыт без свода по релизу
# (`docs/testcases/<release>.evidence.json`). Материал у свода другой — не diff
# по коду, а сколько кейсов в тест-модели, сколько сценариев легло в файлы,
# вердикт сверки и результат прогона.
#
# КОГДА СРАБАТЫВАЕТ. Только если в трейле есть незакрытый цикл тестирования:
# события `phase_transition` с `"loop":"testing"`, у которых последний переход
# по задаче — не в `done`. В проекте, где циклов не запускали, хук молчит и
# ничего не читает дальше первого grep. Это принципиально: гейт, срабатывающий
# в любой сессии, снимут целиком.
#
# ЧТО ТРЕБУЕТ. Наличие свода, а не «зелёный» свод. Свод честно несёт
# `open_items` — прогон не выполнялся, находки не разобраны, загрузка в TMS не
# подтверждена. Требовать APPROVE значило бы сделать гейт неснимаемым там, где
# закрытие находки требует шага, которого в проекте ещё нет.
#
# Снять: /harness hooks disable test-loop-enforcer (R2, причину — в свод).

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

# Повтор, вызванный этим же хуком: агент получил причину и снова остановился.
# Блокировать второй раз — значит зациклить сессию, не дав человеку вмешаться.
if [[ "$(hook_field '.stop_hook_active')" == "true" ]]; then
  echo "[test-loop-enforcer] повторный проход (stop_hook_active) — не блокируем" >&2
  exit 0
fi

AUDIT_DIR=".gigacode/audit"
[[ -d "$AUDIT_DIR" ]] || exit 0

# Дешёвый выход для 99% сессий: ни одного события тестового цикла.
grep -lq '"loop":"testing"' "$AUDIT_DIR"/*.jsonl 2>/dev/null || exit 0

# Последний переход по каждой задаче тестового цикла.
declare -A LAST_TO
declare -A LAST_PHASE
while IFS= read -r line; do
  case "$line" in
    *'"event":"phase_transition"'*'"loop":"testing"'*) ;;
    *) continue ;;
  esac
  task="$(printf '%s' "$line" | sed -nE 's/.*"task_id":"([^"]+)".*/\1/p')"
  to="$(printf '%s' "$line" | sed -nE 's/.*"to":"([^"]+)".*/\1/p')"
  [[ -n "$task" && -n "$to" ]] || continue
  LAST_TO["$task"]="$to"
  LAST_PHASE["$task"]="$to"
done < <(cat "$AUDIT_DIR"/*.jsonl 2>/dev/null)

OPEN=""
for task in "${!LAST_TO[@]}"; do
  [[ "${LAST_TO[$task]}" == "done" ]] && continue
  evidence="docs/testcases/$task.evidence.json"
  [[ -f "$evidence" ]] && continue
  OPEN="${OPEN:+$OPEN }$task(${LAST_PHASE[$task]})"
done

[[ -z "$OPEN" ]] && exit 0

deny "цикл тестирования не закрыт: $OPEN.
Последняя записанная фаза — не done, и свода по релизу нет.

Свод — не формальность: в нём фиксируется, сколько кейсов покрыто сценариями,
какой вердикт дала сверка с тест-моделью, выполнялся ли прогон и что осталось
человеку. Без него «релиз протестирован» — утверждение без опоры.

Собрать:    python3 .gigacode/scripts/collect-test-evidence.py <release>
Состояние:  bash .gigacode/scripts/workflow-state.sh <release>
Продолжить: /test-workflow <release> --resume
Снять гейт: /harness hooks disable test-loop-enforcer"
