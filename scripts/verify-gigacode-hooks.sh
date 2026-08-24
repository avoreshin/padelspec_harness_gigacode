#!/usr/bin/env bash
# verify-gigacode-hooks.sh — диагностика хуков УСТАНОВЛЕННОГО расширения PaDeLSpec.
#
# Отвечает на вопрос «почему хуки не срабатывают после установки
# padelspec_harness_gigacode». Проверяет по каждому wired-хуку ровно те вещи,
# которые ломаются при установке, но не видны в исходном smoke-suite:
#
#   1. окружение   — есть ли bash / jq (без jq большинство хуков молча падает);
#   2. wiring      — прописан ли хук в манифесте / hooks.json и на какое событие;
#   3. файл        — существует, исполняемый (+x), без CRLF, шебанг на месте;
#   4. синтаксис   — `bash -n` проходит;
#   5. запуск      — хук отрабатывает на репрезентативном stdin-событии и НЕ
#                    падает с ошибкой окружения (127/126 = jq нет / не исполняемый);
#   6. блокировка  — 4 guard-хука реально блокируют заведомо плохой ввод (exit 2).
#
# Контракт хука Claude/GigaCode: exit 0 = пропустить, exit 2 = заблокировать.
# ОБА кода — «хук здоров». Любой другой ненулевой код (1, 126, 127, >2) или
# ошибка вида "command not found" — это поломка, которую и ищем.
#
# Использование:
#   bash verify-gigacode-hooks.sh [EXT_DIR]
#     EXT_DIR — корень установленного расширения (где лежит gigacode-extension.json
#               или hooks/). По умолчанию — автоопределение:
#                 1) каталог на уровень выше самого скрипта (scripts/../ );
#                 2) типовые пути установки GigaCode;
#                 3) .gigacode/ в текущем репо (режим проверки исходника).
#
# Exit code: 0 — все хуки здоровы; 1 — есть FAIL; 2 — не найдено расширение.

set -uo pipefail   # НЕ -e: диагностика должна пройти все проверки, а не падать на первой.

# ---------------------------------------------------------------------------
# 0. Цвета / счётчики
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; Z=""
fi
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s  %s\n' "$Y" "$Z" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; }
hdr()  { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }

# ---------------------------------------------------------------------------
# 1. Найти корень расширения и каталог хуков
# ---------------------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

find_ext() {
  # 1) аргумент
  if [ "${1:-}" != "" ]; then printf '%s' "$1"; return; fi
  # 2) на уровень выше скрипта (скрипт живёт в <ext>/scripts/)
  if [ -f "$SELF_DIR/../gigacode-extension.json" ] || [ -d "$SELF_DIR/../hooks" ]; then
    (cd "$SELF_DIR/.." && pwd); return
  fi
  # 3) типовые каталоги установки
  for c in "$HOME/.gigacode/extensions"/* "$HOME/.config/gigacode/extensions"/* \
           "$HOME/.gigacode/extensions/padelspec-harness" \
           "$HOME/.gigacode/extensions"/* ; do
    [ -f "$c/gigacode-extension.json" ] && { printf '%s' "$c"; return; }
  done
  # 4) исходный репо: .gigacode/
  if [ -d "$SELF_DIR/../.gigacode/hooks" ]; then (cd "$SELF_DIR/../.gigacode" && pwd); return; fi
  if [ -d "./.gigacode/hooks" ]; then (cd ./.gigacode && pwd); return; fi
}

EXT="$(find_ext "${1:-}")"
if [ -z "${EXT:-}" ] || [ ! -d "$EXT" ]; then
  printf '%sНе найден каталог расширения.%s Укажи явно: bash %s <EXT_DIR>\n' \
    "$R" "$Z" "$(basename "$0")" >&2
  exit 2
fi
HOOKS_DIR="$EXT/hooks"
[ -d "$HOOKS_DIR" ] || HOOKS_DIR="$EXT/.gigacode/hooks"

printf '%sPaDeLSpec hook doctor%s\n' "$B" "$Z"
printf 'Расширение : %s\n' "$EXT"
printf 'Хуки       : %s\n' "$HOOKS_DIR"

# ---------------------------------------------------------------------------
# 2. Окружение (главные подозреваемые: jq)
# ---------------------------------------------------------------------------
hdr "Окружение"
command -v bash    >/dev/null 2>&1 && ok "bash найден ($(bash --version | head -1))" || bad "bash не найден"
if command -v jq >/dev/null 2>&1; then
  ok "jq найден ($(jq --version 2>/dev/null))"
  HAVE_JQ=1
else
  bad "jq НЕ найден — lib/common.sh и почти все хуки парсят stdin через jq; без jq они молча выходят или падают. Это самая частая причина «хуки не работают». Установи: brew install jq / apt-get install -y jq"
  HAVE_JQ=0
fi
command -v python3 >/dev/null 2>&1 && ok "python3 найден" || warn "python3 не найден — парсинг манифеста ограничен"
command -v node    >/dev/null 2>&1 && ok "node найден (нужен только sdd-schema-gate / validate-schemas)" \
                                    || warn "node не найден — sdd-schema-gate.sh и schema-валидатор работать не будут"

# ---------------------------------------------------------------------------
# 3. Разобрать wiring (какой хук на какое событие) — из всех возможных источников
# ---------------------------------------------------------------------------
# Печатаем строки: <EVENT>\t<MATCHER>\t<RAW_COMMAND>
parse_wiring() {
  # PYTHONUTF8=1 — иначе на Windows с cp1251-локалью печать пути с не-ASCII
  # (напр. C:\Users\Иван\…) падает, а 2>/dev/null прячет traceback: wiring
  # молча выглядит пустым и хук-доктор рапортует ложное «wiring не найден».
  PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python3 - "$EXT" <<'PY' 2>/dev/null
import json, os, sys
ext = sys.argv[1]
srcs = [
    os.path.join(ext, "gigacode-extension.json"),
    os.path.join(ext, "hooks", "hooks.json"),
    os.path.join(ext, "settings.json"),
    os.path.join(ext, ".gigacode", "settings.json"),
]
seen = set()
def emit(hooks):
    # В манифесте v3 ключ "hooks" — это СТРОКА-путь ("hooks/"), а не wiring-словарь.
    # Без этой проверки .items() падал с AttributeError на первом же источнике,
    # разбор обрывался до hooks/hooks.json, а 2>/dev/null прятал traceback —
    # доктор рапортовал ложное «wiring не найден ни из одного источника» для
    # любой корректно собранной сборки.
    if not isinstance(hooks, dict):
        return
    for event, groups in hooks.items():
        if not isinstance(groups, list):
            continue
        for g in groups:
            if not isinstance(g, dict):
                continue
            matcher = g.get("matcher", "*")
            for h in g.get("hooks", []) or []:
                if not isinstance(h, dict):
                    continue
                cmd = h.get("command", "")
                key = (event, matcher, cmd)
                if cmd and key not in seen:
                    seen.add(key)
                    print(f"{event}\t{matcher}\t{cmd}")
for p in srcs:
    if not os.path.isfile(p):
        continue
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception:
        continue
    if not isinstance(d, dict):
        continue
    # манифест v0.5: settings.hooks ; манифест/hooks.json: hooks
    # Источники независимы: сбой на одном не должен обрывать разбор остальных.
    try:
        emit(d.get("hooks"))
        emit((d.get("settings") or {}).get("hooks"))
    except Exception:
        continue
PY
}

hdr "Wiring (событие → хук)"
WIRING="$(parse_wiring)"
if [ -z "$WIRING" ]; then
  bad "Не удалось прочитать wiring ни из одного источника (gigacode-extension.json / hooks/hooks.json / settings.json). Без wiring GigaCode не знает, когда вызывать хуки — они не сработают никогда."
else
  WCOUNT="$(printf '%s\n' "$WIRING" | grep -c . )"
  ok "Найдено wired-привязок: $WCOUNT"
  printf '%s\n' "$WIRING" | awk -F'\t' '{n=$3; sub(/.*\/hooks\//,"",n); printf "        %-16s %-28s %s\n",$1,$2,n}'
fi

# ---------------------------------------------------------------------------
# 4/5/6. Проверка каждого хука
# ---------------------------------------------------------------------------
# Репрезентативный stdin по типу события.
payload_for() {  # $1 = event
  # ВАЖНО: JSON передаём аргументом через `printf '%s'`, а не как формат —
  # иначе printf съест обратные слэши и \n внутри JSON-строк (получится невалидный JSON).
  case "$1" in
    UserPromptSubmit) printf '%s' '{"prompt":"hello world"}' ;;
    Stop|SubagentStop|PreCompact|SessionStart) printf '%s' '{}' ;;
    *) # Pre/PostToolUse — зависит от matcher, но benign payload с обоими полями безопасен
       printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git status","file_path":"src/app.js","content":"const x=1;"}}' ;;
  esac
}

# Заведомо ПЛОХОЙ ввод для guard-хуков (ожидаем exit 2 = block). Только уверенные кейсы.
bad_payload_for() {  # $1 = hook basename  → печатает payload или пусто
  # JSON — аргументом через `printf '%s'` (см. коммент в payload_for).
  case "$1" in
    destructive-command-blocker.sh) printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' ;;
    pii-boundary-check.sh)          printf '%s' '{"tool_name":"Write","tool_input":{"file_path":".env","content":"x"}}' ;;
    commit-message-format.sh)       printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"wip random stuff\""}}' ;;
    branch-naming-gate.sh)          printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git checkout -b RandomBranch"}}' ;;
    *) printf '' ;;
  esac
}

# Множество (event × hook) для запуска: берём из wiring; если wiring пуст —
# гоняем все файлы каталога с benign Bash-событием.
run_targets() {
  if [ -n "$WIRING" ]; then
    printf '%s\n' "$WIRING" | awk -F'\t' '{n=$3; sub(/.*\/hooks\//,"",n); print $1"\t"n}' | sort -u
  else
    for f in "$HOOKS_DIR"/*.sh; do [ -f "$f" ] && printf 'PreToolUse\t%s\n' "$(basename "$f")"; done
  fi
}

# Оценить результат запуска. $1=rc $2=stderr-file → печатает вердикт-строку и класс (ok|warn|bad)
CLASS=""
classify_run() {
  local rc="$1" errf="$2"
  if grep -qiE 'command not found|not found|No such file|jq: (error|not)' "$errf" 2>/dev/null; then
    CLASS="bad"; printf 'ошибка окружения (rc=%s): %s' "$rc" "$(head -1 "$errf")"; return
  fi
  case "$rc" in
    0)   CLASS="ok";   printf 'отработал, пропустил (exit 0)';;
    2)   CLASS="ok";   printf 'отработал, заблокировал (exit 2)';;
    126) CLASS="bad";  printf 'НЕ исполняемый (exit 126) — нужен chmod +x';;
    127) CLASS="bad";  printf 'команда/интерпретатор не найдены (exit 127) — CRLF-шебанг или нет jq';;
    *)   CLASS="warn"; printf 'необычный exit=%s: %s' "$rc" "$(head -1 "$errf" 2>/dev/null)";;
  esac
}

hdr "Проверка хуков (файл · exec · синтаксис · запуск · блокировка)"
TMP="$(mktemp -d 2>/dev/null || echo /tmp/vgh.$$)"; mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

# Уникальный список файлов (для статических проверок — по одному разу на файл)
FILES="$(run_targets | awk -F'\t' '{print $2}' | sort -u)"

for name in $FILES; do
  f="$HOOKS_DIR/$name"
  printf '\n%s• %s%s\n' "$B" "$name" "$Z"

  # -- 4a. файл существует
  if [ ! -f "$f" ]; then
    bad "$name: файл не найден в $HOOKS_DIR (wiring ссылается на несуществующий хук → GigaCode тихо пропустит)"
    continue
  fi
  # -- 4b. исполняемый
  [ -x "$f" ] && ok "$name: исполняемый (+x)" \
              || bad "$name: НЕ исполняемый — GigaCode не запустит. Почини: chmod +x '$f'"
  # -- 4c. CRLF
  if grep -qU $'\r' "$f" 2>/dev/null || LC_ALL=C grep -q $'\r' "$f" 2>/dev/null; then
    bad "$name: CRLF line endings — bash упадёт с \$'\\r': command not found. Почини: sed -i '' 's/\\r$//' '$f'"
  else
    ok "$name: LF (без CRLF)"
  fi
  # -- 4d. шебанг
  head -1 "$f" | grep -qE '^#!' && ok "$name: шебанг на месте" \
                                || warn "$name: нет шебанга в первой строке"
  # -- 4e. синтаксис
  if bash -n "$f" 2>"$TMP/syn.err"; then
    ok "$name: bash -n OK"
  else
    bad "$name: синтаксическая ошибка — $(head -1 "$TMP/syn.err")"
  fi

  # -- 5. запуск на benign payload по КАЖДОМУ событию, к которому привязан хук
  events="$(run_targets | awk -F'\t' -v n="$name" '$2==n{print $1}' | sort -u)"
  [ -z "$events" ] && events="PreToolUse"
  for ev in $events; do
    payload_for "$ev" | bash "$f" >/dev/null 2>"$TMP/run.err"; rc=$?
    verdict="$(classify_run "$rc" "$TMP/run.err")"
    case "$CLASS" in
      ok)   ok   "$name [$ev]: $verdict" ;;
      warn) warn "$name [$ev]: $verdict" ;;
      bad)  bad  "$name [$ev]: $verdict" ;;
    esac
  done

  # -- 6. блокировка заведомо плохого ввода (для guard-хуков)
  bp="$(bad_payload_for "$name")"
  if [ -n "$bp" ]; then
    printf '%s' "$bp" | bash "$f" >/dev/null 2>"$TMP/blk.err"; brc=$?
    if [ "$brc" -eq 2 ]; then
      ok "$name: заблокировал заведомо плохой ввод (exit 2) ✓ enforcement живой"
    elif grep -qiE 'command not found|jq' "$TMP/blk.err" 2>/dev/null; then
      bad "$name: на плохом вводе ошибка окружения ($(head -1 "$TMP/blk.err")) — enforcement НЕ работает"
    else
      bad "$name: НЕ заблокировал заведомо плохой ввод (exit $brc, ожидался 2) — enforcement НЕ работает"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 7. Итог
# ---------------------------------------------------------------------------
hdr "Итог"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' "$G" "$PASS" "$Z" "$Y" "$WARN" "$Z" "$R" "$FAIL" "$Z"
if [ "$FAIL" -gt 0 ]; then
  printf '\n%sХуки НЕ здоровы.%s Первое, что проверить по списку FAIL выше:\n' "$R" "$Z"
  printf '  1) нет jq         → brew install jq  (или apt-get install -y jq)\n'
  printf '  2) нет +x         → chmod +x %s/*.sh\n' "$HOOKS_DIR"
  printf '  3) CRLF           → перегенерировать сборку / sed -i s/\\r//\n'
  printf '  4) пустой wiring  → gigacode-extension.json без settings.hooks: пересобрать расширение\n'
  exit 1
fi
[ "$WARN" -gt 0 ] && printf '\n%sЕсть предупреждения%s — хуки рабочие, но часть возможностей (node-хуки) недоступна.\n' "$Y" "$Z"
printf '\n%sВсе хуки здоровы.%s\n' "$G" "$Z"
exit 0
