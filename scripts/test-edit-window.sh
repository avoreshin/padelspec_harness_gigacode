#!/usr/bin/env bash
# test-edit-window.sh — открыть/закрыть окно правки тестовых файлов.
#
# ЗАЧЕМ. test-files-protector.sh блокирует запись в тестовые файлы, а разрешение
# раньше давалось переменной окружения PDLC_ALLOW_TEST_EDIT=1, которую агенту
# предлагалось выставить командой `export` в Bash. Это не работает: каждый вызов
# Bash-инструмента — отдельный процесс, а хук запускается рантаймом из своего.
# Переменная до хука не доходила ни при каких условиях, то есть test-агент не
# мог создать ни одного теста — ломалась фаза TDD, ради которой существует весь
# цикл. Разрешение теперь передаётся файлом-маркером, видимым обоим процессам.
#
# Использование:
#   test-edit-window.sh open  [reason]   — разрешить правку тестов
#   test-edit-window.sh close            — снять разрешение
#   test-edit-window.sh status           — показать состояние (exit 0 открыто, 1 закрыто)
#
# Окно намеренно недолговечно: держать его открытым дольше фазы Test — то же
# самое, что снять гейт. Кто открыл и зачем — пишется в audit-trail.
#
# Exit codes: 0 — ok (для status: окно открыто); 1 — окно закрыто; 2 — usage.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

COST_DIR=".gigacode/.cost"
MARKER="$COST_DIR/test-edit-allowed"
LOG="$COST_DIR/test-edit-window.log"

usage() {
  echo "usage: test-edit-window.sh open [reason] | close | status" >&2
  exit 2
}

ACTION="${1:-}"
[ -n "$ACTION" ] || usage

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$ACTION" in
  open)
    REASON="${2:-фаза Test}"
    mkdir -p "$COST_DIR"
    printf '%s\t%s\n' "$TS" "$REASON" > "$MARKER"
    printf '%s\topen\t%s\n' "$TS" "$REASON" >> "$LOG"
    echo "окно правки тестов ОТКРЫТО ($REASON). Закрыть после фазы Test: bash .gigacode/scripts/test-edit-window.sh close"
    ;;
  close)
    if [ -f "$MARKER" ]; then
      rm -f "$MARKER"
      printf '%s\tclose\t\n' "$TS" >> "$LOG"
      echo "окно правки тестов закрыто"
    else
      echo "окно правки тестов и так закрыто"
    fi
    ;;
  status)
    if [ -f "$MARKER" ]; then
      echo "открыто: $(cat "$MARKER")"
      exit 0
    fi
    echo "закрыто"
    exit 1
    ;;
  *)
    usage
    ;;
esac
