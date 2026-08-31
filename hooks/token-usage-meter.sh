#!/usr/bin/env bash
# token-usage-meter.sh — Stop / SubagentStop hook: обновляет счётчик токенов,
# на который смотрит cost-circuit-breaker.sh.
#
# ЗАЧЕМ. cost-circuit-breaker читает .gigacode/.cost/task-tokens и сравнивает с
# бюджетом из policies/risk-ladder.yaml. Писателя у этого файла не было ни
# одного: `grep -rn task-tokens` по всему репозиторию находил только сам хук и
# тесты. Счётчик всегда оставался нулём, breaker не срабатывал ни разу, при этом
# в README он числился рабочим гейтом. Этот скрипт закрывает разрыв.
#
# Откуда берутся цифры (первый доступный источник):
#   1. Поля события. GigaCode / GigaCode кладут в Stop `input_tokens` и
#      `context_usage` — это самый дешёвый и точный путь.
#   2. Транскрипт (`transcript_path`). JSONL, где у сообщений есть блок usage;
#      суммируем input+output по всем строкам. Формат транскрипта нигде не
#      зафиксирован как контракт, поэтому разбор намеренно терпимый: не нашли
#      usage — молча не трогаем счётчик, а не пишем ноль.
#
# Счётчик монотонно растёт в пределах задачи и обнуляется при назначении
# risk class (scripts/set-risk-class.sh) — то есть на старте новой задачи.
#
# Никогда не блокирует: это счётчик, гейт — cost-circuit-breaker.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

COST_DIR=".gigacode/.cost"
TOKEN_FILE="$COST_DIR/task-tokens"
mkdir -p "$COST_DIR"

# --- источник 1: поля события ---
TOKENS="$(hook_field_any '.input_tokens' '.context_usage')"

# --- источник 2: транскрипт ---
if ! [[ "$TOKENS" =~ ^[0-9]+$ ]]; then
  TRANSCRIPT="$(hook_field '.transcript_path')"
  if [[ -n "$TRANSCRIPT" && -r "$TRANSCRIPT" ]]; then
    # `..|.usage?` собирает блоки usage на любой глубине — так разбор переживает
    # различия в обёртке сообщения между рантаймами.
    TOKENS="$(jq -s '
      [ .[] | .. | objects | select(has("input_tokens") or has("output_tokens"))
      | ((.input_tokens // 0) + (.output_tokens // 0)) ] | add // empty
    ' "$TRANSCRIPT" 2>/dev/null || true)"
  fi
fi

# Ничего не нашли — счётчик не трогаем. Записать ноль было бы хуже, чем не
# записать ничего: это сбросило бы уже накопленный расход.
[[ "$TOKENS" =~ ^[0-9]+$ ]] || exit 0

CURRENT=0
if [[ -f "$TOKEN_FILE" ]]; then
  CURRENT=$(cat "$TOKEN_FILE" 2>/dev/null || echo 0)
  [[ "$CURRENT" =~ ^[0-9]+$ ]] || CURRENT=0
fi

# Монотонность: источники дают разные срезы (расход за сессию против расхода за
# задачу), и меньшее значение не означает, что потрачено меньше.
if [[ "$TOKENS" -gt "$CURRENT" ]]; then
  printf '%s\n' "$TOKENS" > "$TOKEN_FILE"
  echo "[token-usage-meter] task-tokens: $CURRENT → $TOKENS" >&2
fi

exit 0
