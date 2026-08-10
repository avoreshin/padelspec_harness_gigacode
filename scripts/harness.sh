#!/usr/bin/env bash
# harness.sh — control panel обвязки: доктор зависимостей, валидация схем,
#              включение/отключение хук-скриптов.
#
# Подкоманды:
#   doctor [--install]      — проверить бинарники + node-пакеты (ajv…) + компиляцию схем
#   schemas [all|<name>]    — валидировать JSON-схемы (обёртка над validate-schemas.sh)
#   hooks list              — показать хуки по событиям + отключённые
#   hooks disable <name>    — отключить хук-скрипт (перенести в $disabled_hooks)
#   hooks enable  <name>    — снова включить хук-скрипт
#
# Read-only, кроме `hooks enable|disable` (правят .gigacode/settings.json с бэкапом).
# Exit: 0 — ok, 1 — что-то не так (missing dep / invalid schema), 2 — usage/internal.

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not inside a git repository" >&2; exit 2; }
cd "$REPO_ROOT"

if [ -t 1 ]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_DIM=""; C_BOLD=""; C_RESET=""
fi

SETTINGS=".gigacode/settings.json"
SCHEMA_DIR=".gigacode/schemas"
CACHE_NM=".gigacode/.cache/node/node_modules"
VALIDATE_SCHEMAS=".gigacode/scripts/validate-schemas.sh"
VALIDATOR_JS=".gigacode/scripts/_validator.js"

ok()   { printf '  %s✅%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
bad()  { printf '  %s❌%s %s\n' "$C_RED" "$C_RESET" "$1"; }
warn() { printf '  %s⚠️%s  %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
sect() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------

REQ_BINS=("git" "node" "npm")
OPT_BINS=("python3" "perl" "pip3" "pre-commit" "rsync")
NODE_PKGS=("ajv" "ajv-formats" "js-yaml")

hint_for() {
  case "$1" in
    git)        echo "xcode-select --install  |  brew install git" ;;
    node|npm)   echo "brew install node  (или nvm install --lts)" ;;
    python3)    echo "brew install python" ;;
    perl)       echo "предустановлен в macOS; в Linux — apt install perl" ;;
    pip3)       echo "часть python3" ;;
    pre-commit) echo "pipx install pre-commit  (нужно для CI/CD enforcement)" ;;
    rsync)      echo "brew install rsync" ;;
    *)          echo "" ;;
  esac
}

cmd_doctor() {
  local install=false
  [ "${1:-}" = "--install" ] && install=true
  local fail=0

  sect "🔧 Обязательные бинарники"
  for b in "${REQ_BINS[@]}"; do
    if command -v "$b" >/dev/null 2>&1; then
      local ver=""
      case "$b" in
        node) ver=" $(node --version 2>/dev/null)";;
        npm)  ver=" v$(npm --version 2>/dev/null)";;
        git)  ver=" $(git --version 2>/dev/null | awk '{print $3}')";;
      esac
      ok "$b$ver"
    else
      bad "$b — НЕ найден  ($C_DIM$(hint_for "$b")$C_RESET)"; fail=1
    fi
  done

  if command -v node >/dev/null 2>&1; then
    local major; major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)"
    if [ -n "$major" ] && [ "$major" -lt 18 ]; then
      warn "node $major.x — рекомендуется ≥ 18 для ajv@8"
    fi
  fi

  sect "🧰 Опциональные бинарники (используются отдельными скриптами)"
  for b in "${OPT_BINS[@]}"; do
    if command -v "$b" >/dev/null 2>&1; then ok "$b"; else warn "$b — нет  ($C_DIM$(hint_for "$b")$C_RESET)"; fi
  done

  sect "📦 Node-пакеты валидатора (.gigacode/.cache/node/)"
  local missing_pkgs=0
  for p in "${NODE_PKGS[@]}"; do
    if [ -f "$CACHE_NM/$p/package.json" ]; then
      local pv; pv="$(node -p "require('./$CACHE_NM/$p/package.json').version" 2>/dev/null)"
      ok "$p${pv:+ v$pv}"
    else
      bad "$p — не установлен в кэше"; missing_pkgs=1
    fi
  done
  if [ "$missing_pkgs" -eq 1 ]; then
    if $install && command -v node >/dev/null 2>&1; then
      printf '  %s· устанавливаю (ajv + ajv-formats + js-yaml)…%s\n' "$C_DIM" "$C_RESET"
      local anyschema; anyschema="$(ls "$SCHEMA_DIR"/*.schema.json 2>/dev/null | head -1)"
      if [ -n "$anyschema" ] && node "$VALIDATOR_JS" compile "$anyschema" >/dev/null 2>&1; then
        ok "пакеты установлены"
      else
        bad "автоустановка не удалась — запусти: node $VALIDATOR_JS compile $anyschema"; fail=1
      fi
    else
      warn "запусти  ${C_CYAN}bash .gigacode/scripts/harness.sh doctor --install${C_RESET}  (или любой validate-schemas.sh) для one-time установки"
      fail=1
    fi
  fi

  sect "🧩 Компиляция JSON-схем (.gigacode/schemas/)"
  local n=0 sf=0
  for s in "$SCHEMA_DIR"/*.schema.json; do
    [ -e "$s" ] || continue
    n=$((n+1))
    if node "$VALIDATOR_JS" compile "$s" >/dev/null 2>&1; then
      ok "$(basename "$s")"
    else
      bad "$(basename "$s") — не компилируется"; sf=1
    fi
  done
  [ "$n" -eq 0 ] && warn "схемы не найдены в $SCHEMA_DIR/"
  [ "$sf" -eq 1 ] && fail=1

  printf '\n'
  if [ "$fail" -eq 0 ]; then
    printf '%s🎉 harness готов%s — все обязательные зависимости на месте, схемы компилируются.\n' "$C_GREEN" "$C_RESET"
    return 0
  fi
  printf '%s🔴 есть проблемы%s — см. ❌ выше. Обязательные пакеты недоступны или схемы не компилируются.\n' "$C_RED" "$C_RESET"
  return 1
}

# ---------------------------------------------------------------------------
# schemas — обёртка над validate-schemas.sh
# ---------------------------------------------------------------------------

cmd_schemas() {
  local arg="${1:-compile}"
  [ -x "$VALIDATE_SCHEMAS" ] || { err "$VALIDATE_SCHEMAS не найден/не исполняемый"; exit 2; }
  case "$arg" in
    all)     bash "$VALIDATE_SCHEMAS" all ;;
    compile) bash "$VALIDATE_SCHEMAS" compile ;;
    *)       bash "$VALIDATE_SCHEMAS" validate "$arg" "${2:?usage: harness.sh schemas <schema> <file>}" ;;
  esac
}

# ---------------------------------------------------------------------------
# hooks — enable/disable/list через settings.json
# ---------------------------------------------------------------------------

require_settings() { [ -f "$SETTINGS" ] || { err "$SETTINGS не найден"; exit 2; }; }

cmd_hooks() {
  require_settings
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)    hooks_list ;;
    disable) hooks_toggle disable "${1:?usage: harness.sh hooks disable <name>}" ;;
    enable)  hooks_toggle enable  "${1:?usage: harness.sh hooks enable <name>}" ;;
    *)       err "unknown: hooks $sub (list|enable|disable)"; exit 2 ;;
  esac
}

hooks_list() {
  python3 - "$SETTINGS" <<'PY'
import json,sys,re
d=json.load(open(sys.argv[1]))
def name(c):
    m=re.search(r'([\w-]+\.sh)',c); return m.group(1) if m else c[:48]
print("\033[1m🪝 Активные хуки (по событиям)\033[0m")
for ev,arr in d.get('hooks',{}).items():
    names=[name(hk.get('command','')) for m in arr for hk in m.get('hooks',[])]
    print(f"  \033[36m{ev}\033[0m: "+", ".join(names))
dis=d.get('$disabled_hooks',[])
print("\n\033[1m⛔ Отключённые\033[0m")
if not dis:
    print("  \033[2m✅ — нет —\033[0m")
else:
    for r in dis:
        print(f"  \033[33m{name(r['hook'].get('command',''))}\033[0m  (event: {r['event']}, matcher: {r.get('matcher','—')})")
PY
}

hooks_toggle() {
  local action="$1" nm="$2"
  cp "$SETTINGS" "$SETTINGS.bak" || { err "не смог сделать бэкап"; exit 2; }
  local result
  result="$(python3 - "$SETTINGS" "$action" "$nm" <<'PY'
import json,sys,re
path,action,nm=sys.argv[1],sys.argv[2],sys.argv[3]
d=json.load(open(path))
d.setdefault('hooks',{})
d.setdefault('$disabled_hooks',[])
def has(c): return nm in (c or '')
moved=0
if action=='disable':
    for ev,arr in list(d['hooks'].items()):
        for grp in arr:
            keep=[]
            for hk in grp.get('hooks',[]):
                if has(hk.get('command','')):
                    d['$disabled_hooks'].append({'event':ev,'matcher':grp.get('matcher'),'hook':hk})
                    moved+=1
                else:
                    keep.append(hk)
            grp['hooks']=keep
        d['hooks'][ev]=[g for g in arr if g.get('hooks')]
        if not d['hooks'][ev]:
            del d['hooks'][ev]
elif action=='enable':
    rest=[]
    for r in d['$disabled_hooks']:
        if has(r['hook'].get('command','')):
            ev=r['event']; matcher=r.get('matcher')
            arr=d['hooks'].setdefault(ev,[])
            grp=next((g for g in arr if g.get('matcher')==matcher),None)
            if grp is None:
                grp={}
                if matcher is not None: grp['matcher']=matcher
                grp['hooks']=[]; arr.append(grp)
            grp.setdefault('hooks',[]).append(r['hook'])
            moved+=1
        else:
            rest.append(r)
    d['$disabled_hooks']=rest
else:
    print("ERR:bad action"); sys.exit(2)
if not d['$disabled_hooks']:
    d.pop('$disabled_hooks',None)
json.dump(d,open(path,'w'),indent=2,ensure_ascii=False)
open(path,'a').write("\n")
print(f"OK:{moved}")
PY
)"
  if [[ "$result" == OK:* ]]; then
    local cnt="${result#OK:}"
    if [ "$cnt" -eq 0 ]; then
      warn "хук '$nm' не найден среди $( [ "$action" = enable ] && echo отключённых || echo активных )"
      mv "$SETTINGS.bak" "$SETTINGS"
    else
      rm -f "$SETTINGS.bak"
      if [ "$action" = disable ]; then
        printf '%s⛔ отключено%s: %s (%s хук(а/ов)). Включить: %sbash .gigacode/scripts/harness.sh hooks enable %s%s\n' \
          "$C_YELLOW" "$C_RESET" "$nm" "$cnt" "$C_CYAN" "$nm" "$C_RESET"
        printf '  %s⚠️  отключение enforcement-хука — это R2/compliance-риск. Зафиксируй причину.%s\n' "$C_DIM" "$C_RESET"
      else
        printf '%s✅ включено%s: %s (%s хук(а/ов)).\n' "$C_GREEN" "$C_RESET" "$nm" "$cnt"
      fi
    fi
  else
    err "не удалось изменить settings.json (восстановлен бэкап): $result"
    mv "$SETTINGS.bak" "$SETTINGS"
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

usage() {
  cat >&2 <<EOF
${C_BOLD}harness.sh${C_RESET} — control panel обвязки

  ${C_CYAN}doctor${C_RESET} [--install]      проверить пакеты (ajv и др.) + компиляцию схем
  ${C_CYAN}schemas${C_RESET} [all|<name>]    валидировать JSON-схемы (обёртка validate-schemas.sh)
  ${C_CYAN}hooks list${C_RESET}              показать активные/отключённые хук-скрипты
  ${C_CYAN}hooks disable${C_RESET} <name>    отключить хук (обратимо, в \$disabled_hooks)
  ${C_CYAN}hooks enable${C_RESET}  <name>    снова включить хук

Примеры:
  bash .gigacode/scripts/harness.sh doctor
  bash .gigacode/scripts/harness.sh doctor --install
  bash .gigacode/scripts/harness.sh schemas all
  bash .gigacode/scripts/harness.sh hooks disable slash-command-lint
EOF
  exit 2
}

[ $# -lt 1 ] && usage
cmd="$1"; shift
case "$cmd" in
  doctor)  cmd_doctor "${1:-}" ;;
  schemas) cmd_schemas "$@" ;;
  hooks)   cmd_hooks "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command: $cmd"; usage ;;
esac
