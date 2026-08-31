#!/usr/bin/env bash
# setup-mcp-atlassian.sh — обвязка для настройки MCP-серверов Atlassian
# (Confluence Sigma, Confluence Delta, Jira Delta) в GigaCode.
#
# Вся установка живёт в платформенных скриптах mcp/configure-*.{sh,bat}. Здесь —
# то, что нужно мастеру /setup-mcp: осмотреть машину до изменений, запустить
# нужный скрипт без единого интерактивного промпта и проверить результат.
#
# Почему через файл учётных данных, а не через промпты: платформенные скрипты
# спрашивают токены через `read`, а у Bash-инструмента агента нет TTY. Но они же
# умеют читать ${HOME}/.giga_sberosc и в этом случае не спрашивают ничего — этим
# и пользуемся. Файл создаётся с правами 600 и удаляется по trap в любом исходе,
# включая падение pip: иначе четыре боевых токена остаются лежать открытым
# текстом до следующего успешного прогона.
#
# Usage:
#   bash setup-mcp-atlassian.sh check
#   bash setup-mcp-atlassian.sh apply                 # значения через окружение
#   bash setup-mcp-atlassian.sh apply --tokens-only   # только ротация токенов
#   bash setup-mcp-atlassian.sh verify
#
# apply читает из окружения:
#   SIGMA_TOKEN  DELTA_TOKEN  JIRA_DELTA_TOKEN  SBEROSC_TOKEN  MAIL_ADDRESS
#   PYTHON_EXE_PATH — только Windows и только если venv ещё нет
#
# Коды возврата: 0 — успех, 1 — блокирующая проблема, 2 — ошибка вызова.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$SCRIPT_DIR/mcp"
CREDENTIALS_FILE="${HOME}/.giga_sberosc"
SETTINGS_FILE="${HOME}/.gigacode/settings.json"

OK=0
WARN=0
FAIL=0

ok()   { printf 'OK   %s\n'   "$1"; OK=$((OK+1)); }
warn() { printf 'WARN %s\n'   "$1"; WARN=$((WARN+1)); }
fail() { printf 'FAIL %s\n'   "$1"; FAIL=$((FAIL+1)); }
die()  { printf 'ERROR %s\n'  "$1" >&2; exit 2; }

detect_os() {
  case "$(uname -s 2>/dev/null || echo "${OS:-}")" in
    Linux)                      echo linux   ;;
    Darwin)                     echo macos   ;;
    MINGW*|MSYS*|CYGWIN*)       echo windows ;;
    *) [[ "${OS:-}" == "Windows_NT" ]] && echo windows || echo unknown ;;
  esac
}

# Интерпретатор, которым платформенный скрипт создаёт venv и которым мы читаем
# JSON в check/verify. На Windows под git-bash python3 обычно нет.
host_python() {
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
  done
  return 1
}

# Сервер запускается интерпретатором из venv. Где venv — зависит от платформы,
# поэтому путь берём не из догадки, а из самого settings.json (см. verify).
json_get() {
  # json_get <файл> <jq-подобный путь через python>
  local py; py="$(host_python)" || return 1
  "$py" - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
cur = data
for part in sys.argv[2].split("."):
    if part == "":
        continue
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
        cur = cur[int(part)]
    else:
        sys.exit(1)
print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur, ensure_ascii=False))
PY
}

# ============================================================================
# check — только осмотр, ничего не меняет
# ============================================================================
cmd_check() {
  local os; os="$(detect_os)"
  printf 'Платформа: %s\n\n' "$os"
  [[ "$os" == "unknown" ]] && fail "не удалось определить ОС (uname -s: $(uname -s 2>&1))"

  local py=""
  if py="$(host_python)"; then
    ok "python: $(command -v "$py") ($("$py" --version 2>&1))"
  else
    fail "python не найден в PATH — venv создать нечем"
  fi

  if command -v node >/dev/null 2>&1; then
    ok "node: $(node --version 2>&1)"
  else
    warn "node не найден — нужен для самого GigaCode CLI, не для MCP-серверов"
  fi

  # Рабочая директория SberOS: платформенный скрипт без неё завершается ошибкой.
  local work_dir=""
  if [[ "$os" == "linux" ]]; then
    work_dir="$(find /home/work -maxdepth 1 -type d -name '*[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*' 2>/dev/null | head -n 1)"
    if [[ -n "$work_dir" ]]; then
      ok "рабочая директория: $work_dir"
    else
      fail "в /home/work нет каталога с табельным номером — configure-linux.sh остановится на шаге 5"
    fi
  fi

  # Наличие venv решает, будет ли .bat спрашивать путь к python.exe: мастер
  # задаёт этот вопрос только когда venv ещё нет.
  local venv="${HOME}/.venv"
  [[ "$os" == "linux" && -n "${work_dir:-}" ]] && venv="$work_dir/.venv"
  if [[ -d "$venv" ]]; then
    ok "venv уже есть: $venv (пакеты будут переустановлены поверх)"
  else
    ok "venv будет создан: $venv"
  fi

  # ~/.npmrc переписывается целиком, а не дополняется.
  if [[ -f "${HOME}/.npmrc" ]]; then
    warn "${HOME}/.npmrc существует и будет ПЕРЕЗАПИСАН целиком (сделайте копию, если там свои настройки)"
  else
    ok "${HOME}/.npmrc будет создан"
  fi

  if [[ -f "$SETTINGS_FILE" ]]; then
    local servers
    servers="$(json_get "$SETTINGS_FILE" "mcpServers")"
    if [[ -n "$servers" ]]; then
      local names
      names="$("$py" -c 'import json,sys; print(", ".join(json.loads(sys.argv[1]).keys()) or "—")' "$servers" 2>/dev/null)"
      ok "settings.json валиден, серверы: ${names:-—}"
      if printf '%s' "$servers" | grep -q '"atlassian"'; then
        warn "серверы atlassian / delta-confluence уже настроены — будут перезаписаны новыми токенами"
      fi
    else
      warn "settings.json существует, но невалиден — будет перезаписан"
    fi
  else
    ok "settings.json будет создан"
  fi

  if [[ -f "$CREDENTIALS_FILE" ]]; then
    warn "$CREDENTIALS_FILE остался от прошлого запуска и содержит токены открытым текстом — будет перезаписан и удалён"
  fi

  printf '\nИтог: OK %d · WARN %d · FAIL %d\n' "$OK" "$WARN" "$FAIL"
  [[ "$FAIL" -gt 0 ]] && return 1
  return 0
}

# ============================================================================
# apply — запуск платформенного скрипта без интерактивных промптов
# ============================================================================
write_credentials() {
  local dialect="$1"
  local old_umask; old_umask="$(umask)"
  umask 077
  if [[ "$dialect" == "bat" ]]; then
    # PowerShell-читалка в .bat разбирает строки как KEY=VALUE без кавычек:
    # кавычки из bash-диалекта приехали бы внутрь значения токена.
    {
      printf 'sigma_token=%s\n'      "$SIGMA_TOKEN"
      printf 'delta_token=%s\n'      "$DELTA_TOKEN"
      printf 'jira_delta_token=%s\n' "$JIRA_DELTA_TOKEN"
      printf 'sberosc_token=%s\n'    "$SBEROSC_TOKEN"
      printf 'mail_address=%s\n'     "$MAIL_ADDRESS"
    } > "$CREDENTIALS_FILE"
  else
    # Одинарные кавычки, а не двойные: значение уходит в `source` как есть,
    # без подстановки $ и обратных слэшей.
    {
      printf "sigma_token='%s'\n"      "$SIGMA_TOKEN"
      printf "delta_token='%s'\n"      "$DELTA_TOKEN"
      printf "jira_delta_token='%s'\n" "$JIRA_DELTA_TOKEN"
      printf "sberosc_token='%s'\n"    "$SBEROSC_TOKEN"
      printf "mail_address='%s'\n"     "$MAIL_ADDRESS"
    } > "$CREDENTIALS_FILE"
  fi
  umask "$old_umask"
  chmod 600 "$CREDENTIALS_FILE" 2>/dev/null || true
}

# Обновление токенов без переустановки: пути к venv берутся из уже записанного
# конфига, поэтому знать платформу и звать платформенный скрипт не нужно.
# SBEROSC_TOKEN здесь не участвует — он живёт в ~/.npmrc и в индексе pip, а не в
# settings.json; его ротация требует полного apply.
cmd_apply_tokens_only() {
  local missing=()
  for v in SIGMA_TOKEN DELTA_TOKEN JIRA_DELTA_TOKEN MAIL_ADDRESS; do
    [[ -z "${!v:-}" ]] && missing+=("$v")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "не заданы переменные окружения: ${missing[*]}"

  [[ -f "$SETTINGS_FILE" ]] || die "$SETTINGS_FILE не найден — обновлять нечего, нужен полный apply"

  local py=""; py="$(host_python)" || die "python не найден"
  local cmd entry
  cmd="$(json_get "$SETTINGS_FILE" "mcpServers.atlassian.command")"
  entry="$(json_get "$SETTINGS_FILE" "mcpServers.atlassian.args.0")"
  [[ -n "$cmd" && -n "$entry" ]] || die "в $SETTINGS_FILE нет сервера atlassian — нужен полный apply"

  MCP_SETTINGS="$SETTINGS_FILE" MCP_PYTHON="$cmd" MCP_ATLASSIAN="$entry" \
  MCP_MAIL="$MAIL_ADDRESS" MCP_SIGMA_TOKEN="$SIGMA_TOKEN" \
  MCP_DELTA_TOKEN="$DELTA_TOKEN" MCP_JIRA_TOKEN="$JIRA_DELTA_TOKEN" \
    "$py" "$MCP_DIR/merge-settings.py" || return 1

  printf '    токены обновлены, пакеты и ~/.npmrc не тронуты\n'
  return 0
}

cmd_apply() {
  [[ "${1:-}" == "--tokens-only" ]] && { cmd_apply_tokens_only; return $?; }

  local missing=()
  for v in SIGMA_TOKEN DELTA_TOKEN JIRA_DELTA_TOKEN SBEROSC_TOKEN MAIL_ADDRESS; do
    [[ -z "${!v:-}" ]] && missing+=("$v")
  done
  [[ ${#missing[@]} -gt 0 ]] && die "не заданы переменные окружения: ${missing[*]}"

  local os; os="$(detect_os)"
  # Файл с токенами не должен пережить ни успех, ни падение платформенного скрипта.
  trap 'rm -f "$CREDENTIALS_FILE"' EXIT INT TERM

  local rc=0
  case "$os" in
    linux)
      write_credentials sh
      bash "$MCP_DIR/configure-linux.sh" || rc=$?
      ;;
    macos)
      write_credentials sh
      bash "$MCP_DIR/configure-macos.sh" || rc=$?
      ;;
    windows)
      write_credentials bat
      local bat="$MCP_DIR/configure-windows.bat"
      command -v cygpath >/dev/null 2>&1 && bat="$(cygpath -w "$bat")"
      # Единственный промпт .bat вне файла учётных данных — путь к python.exe,
      # и только когда venv ещё нет. Подаём ответ на stdin: `set /p` читает его.
      printf '%s\n' "${PYTHON_EXE_PATH:-}" | cmd.exe /c "$bat" || rc=$?
      ;;
    *)
      die "неподдерживаемая платформа: $(uname -s 2>&1)"
      ;;
  esac

  rm -f "$CREDENTIALS_FILE"
  return "$rc"
}

# ============================================================================
# verify — проверка результата
# ============================================================================
cmd_verify() {
  local py=""
  py="$(host_python)" || die "python не найден — проверить конфиг нечем"

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    fail "$SETTINGS_FILE не создан"
    printf '\nИтог: OK %d · WARN %d · FAIL %d\n' "$OK" "$WARN" "$FAIL"
    return 1
  fi

  if ! "$py" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$SETTINGS_FILE" 2>/dev/null; then
    fail "$SETTINGS_FILE — невалидный JSON"
    printf '\nИтог: OK %d · WARN %d · FAIL %d\n' "$OK" "$WARN" "$FAIL"
    return 1
  fi
  ok "settings.json валиден"

  local server cmd entry
  for server in atlassian delta-confluence; do
    cmd="$(json_get "$SETTINGS_FILE" "mcpServers.$server.command")"
    if [[ -z "$cmd" ]]; then
      fail "сервер $server отсутствует в mcpServers"
      continue
    fi
    entry="$(json_get "$SETTINGS_FILE" "mcpServers.$server.args.0")"

    # Здесь ловится расхождение «venv создан в одном месте, в конфиг записано
    # другое»: JSON валиден, сервер описан, а запускать нечего.
    if [[ -x "$cmd" ]]; then
      ok "$server → интерпретатор на месте: $cmd"
    else
      fail "$server → интерпретатор не найден или не исполняемый: $cmd"
    fi
    if [[ -e "$entry" ]]; then
      ok "$server → точка входа на месте: $entry"
    else
      fail "$server → точка входа не найдена: $entry"
    fi
  done

  # Живой запуск: пакет может быть на месте, но не импортироваться.
  if [[ "$FAIL" -eq 0 ]]; then
    cmd="$(json_get "$SETTINGS_FILE" "mcpServers.atlassian.command")"
    entry="$(json_get "$SETTINGS_FILE" "mcpServers.atlassian.args.0")"
    if timeout 30 "$cmd" "$entry" --help >/dev/null 2>&1; then
      ok "mcp-atlassian запускается"
    else
      warn "mcp-atlassian не ответил на --help за 30 с — проверьте вручную: $cmd $entry --help"
    fi
  fi

  [[ -f "$CREDENTIALS_FILE" ]] && fail "$CREDENTIALS_FILE не удалён — в нём лежат токены открытым текстом"

  printf '\nИтог: OK %d · WARN %d · FAIL %d\n' "$OK" "$WARN" "$FAIL"
  [[ "$FAIL" -gt 0 ]] && return 1
  return 0
}

SUB="${1:-}"
shift 2>/dev/null || true
case "$SUB" in
  check)  cmd_check       ;;
  apply)  cmd_apply "$@"  ;;
  verify) cmd_verify      ;;
  *) die "usage: setup-mcp-atlassian.sh {check|apply [--tokens-only]|verify}" ;;
esac
