#!/usr/bin/env bash
# autotest-run.sh — прогон сгенерированных Cucumber-сценариев и разбор падений.
#
# Нужен отладочному циклу `/generate-autotests --debug`: цикл имеет право чинить
# только то, за что отвечает генератор, и должен останавливаться, когда причина
# вне его зоны. Решение «чинить или отдать человеку» принимается здесь по
# шаблонам, а не моделью по впечатлению от лога.
#
# Граница зоны ответственности:
#   в зоне  — сценарий не сматчился с реализацией, не собрался, передал не то
#             или не всё: шаг не найден, шаг неоднозначен, неизвестный
#             parameter type, синтаксис Gherkin, ClassCastException на
#             stash-значении, NPE от непереданного поля;
#   вне зоны — сценарий доехал до проверки, сообщение ушло, а результат не
#             совпал с ожиданием. Это дефект продукта либо неверное ожидание в
#             тест-модели, и правкой feature-файла не лечится;
#   инфра   — прогона не было вовсе: Maven не собрал, стенд недоступен.
#
# Usage:
#   autotest-run.sh dry-run  "<tags>" [--project DIR]
#   autotest-run.sh run      "<tags>" [--project DIR]
#   autotest-run.sh classify <logfile>
#
# Коды возврата:
#   0 — прогон чистый
#   1 — есть находки В ЗОНЕ генератора (цикл может чинить)
#   2 — падение ВНЕ зоны (останов, отдать человеку)
#   3 — инфраструктура (останов, чинить окружение)
#   4 — ошибка вызова или лог не разобран

set -uo pipefail

PROJECT="."
SUB="${1:-}"
shift 2>/dev/null || true

die() { printf 'ERROR %s\n' "$1" >&2; exit 4; }

# ---------------------------------------------------------------------------
# Классификация. Порядок важен: сначала «прогона не было», потом структурные
# несовпадения, потом рантайм, и только затем проверки. Вердикт — самая
# приоритетная из найденных категорий, находки печатаются все.
# ---------------------------------------------------------------------------
classify() {
  local log="$1"
  [[ -f "$log" ]] || die "лог не найден: $log"

  local -a findings=()
  local zone_infra=0 zone_fix=0 zone_out=0

  add() { findings+=("$1|$2|$3"); }
  hit() { grep -qEi -- "$1" "$log"; }

  # --- инфраструктура: тестов не было ---
  if hit 'Could not resolve dependencies|Non-resolvable|Could not transfer artifact|PKIX path building failed|Failed to read artifact descriptor'; then
    add INFRA maven-deps "Maven не разрешил зависимости — прогона не было"; zone_infra=1
  fi
  if hit 'mvn: command not found|No such file or directory.*mvn'; then
    add INFRA maven-missing "Maven не найден в PATH"; zone_infra=1
  fi
  if hit 'Connection refused|UnknownHostException|SocketTimeoutException|Connection timed out|NoRouteToHost'; then
    add INFRA stand-unreachable "Стенд или брокер недоступны — это окружение, не сценарий"; zone_infra=1
  fi

  # --- в зоне: структура сценария ---
  if hit 'UndefinedStepException|The step .* is undefined|You can implement missing steps|undefined step'; then
    add FIX step-undefined "Шаг не сматчился с реализацией — текст шага или значение ParameterTypes"; zone_fix=1
  fi
  if hit 'AmbiguousStepDefinitionsException'; then
    add FIX step-ambiguous "Шаг подошёл под две реализации — нужен более точный текст"; zone_fix=1
  fi
  if hit 'UndefinedParameterTypeException|Undefined parameter type'; then
    add FIX parameter-type "Использован parameter type, которого нет в ParameterTypes"; zone_fix=1
  fi
  if hit 'io\.cucumber\.gherkin|ParserException|Parser errors|inconsistent cell count'; then
    add FIX gherkin-parse "Синтаксис Gherkin: таблица, отступ или ключевое слово"; zone_fix=1
  fi

  # --- в зоне: сценарий передал не то ---
  if hit 'ClassCastException'; then
    add FIX stash-type "Тип stash-значения не тот, которого ждёт шаг"; zone_fix=1
  fi
  if hit 'NullPointerException'; then
    add FIX missing-field "Похоже, в таблицу не передано обязательное поле. Если две правки подряд не помогли — причина вне зоны"; zone_fix=1
  fi
  if hit 'IllegalArgumentException|NumberFormatException|DateTimeParseException'; then
    add FIX bad-value "Значение в таблице не разобралось — формат или словарь"; zone_fix=1
  fi

  # --- вне зоны: сообщение ушло, результат не совпал ---
  if hit 'AssertionError|AssertionFailedError|ComparisonFailure|org\.opentest4j|expected:.*but was:|Ожидалось|ожидаемый результат'; then
    add OUT assertion "Сценарий доехал до проверки — результат не совпал с ожиданием. Дефект продукта либо ожидание в тест-модели"; zone_out=1
  fi

  # --- чисто ---
  if [[ ${#findings[@]} -eq 0 ]]; then
    if hit 'BUILD SUCCESS|Tests run:.*Failures: 0.*Errors: 0'; then
      printf 'VERDICT: pass\nSIGNATURE: clean\n'
      return 0
    fi
    printf 'VERDICT: unknown\nSIGNATURE: unknown\n'
    printf -- '--- находки ---\n'
    printf 'UNKNOWN  no-pattern  Лог не совпал ни с одним известным шаблоном — разобрать глазами: %s\n' "$log"
    return 4
  fi

  local verdict rc
  if   (( zone_infra )); then verdict=infra;        rc=3
  elif (( zone_fix  )); then verdict=fix;           rc=1
  elif (( zone_out  )); then verdict=out-of-scope;  rc=2
  else                        verdict=unknown;      rc=4
  fi

  # Подпись прогона: набор категорий. Две итерации с одинаковой подписью —
  # прогресса нет, цикл обязан остановиться, а не крутиться на том же месте.
  local signature
  signature="$(printf '%s\n' "${findings[@]}" | cut -d'|' -f2 | sort -u | tr '\n' ',' | sed 's/,$//')"

  printf 'VERDICT: %s\nSIGNATURE: %s\n' "$verdict" "$signature"
  printf -- '--- находки ---\n'
  local f
  for f in "${findings[@]}"; do
    printf '%-5s %-16s %s\n' "${f%%|*}" "$(printf '%s' "$f" | cut -d'|' -f2)" "${f##*|}"
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
run_maven() {
  local mode="$1" tags="$2"
  [[ -n "$tags" ]] || die "не задано выражение тегов"
  command -v mvn >/dev/null 2>&1 || { printf 'VERDICT: infra\nSIGNATURE: maven-missing\n'; return 3; }

  local log; log="$(mktemp -t autotest-run-XXXXXX.log)"
  local -a cmd=(mvn test "-Dcucumber.filter.tags=$tags")
  [[ "$mode" == "dry-run" ]] && cmd+=("-Dcucumber.execution.dry-run=true")

  printf 'Запуск: %s\nЛог: %s\n\n' "${cmd[*]}" "$log"
  ( cd "$PROJECT" && "${cmd[@]}" ) > "$log" 2>&1
  local rc=$?
  printf 'Maven завершился с кодом %d\n\n' "$rc"
  classify "$log"
}

case "$SUB" in
  dry-run|run)
    TAGS="${1:-}"
    shift 2>/dev/null || true
    [[ "${1:-}" == "--project" ]] && { PROJECT="${2:-.}"; }
    run_maven "$SUB" "$TAGS"
    ;;
  classify)
    classify "${1:-}"
    ;;
  *)
    die "usage: autotest-run.sh {dry-run <tags>|run <tags>|classify <logfile>} [--project DIR]"
    ;;
esac
