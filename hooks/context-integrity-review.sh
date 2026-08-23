#!/usr/bin/env bash
# context-integrity-review.sh
# PreCompact hook: сохраняет critical state перед сжатием контекста.
# Согласно §2.10 (5-уровневое сжатие) и §4.4 PDLC v3.5.
#
# Когда срабатывает:
#   Перед сжатием контекста рантайм вызывает этот hook. Hook:
#     1. Снимает snapshot текущего состояния (open SDD, current risk class,
#        pending failing tests, наличие evidence bundle).
#     2. Пишет в .gigacode/.context-snapshots/<timestamp>.json
#     3. Проверяет, что критическое состояние не теряется при сжатии.
#     4. Если теряется — отказ + причина.
#
# КОНТРАКТ СОБЫТИЯ. PreCompact отдаёт `trigger` ("auto" | "manual") и
# `custom_instructions` — и в GigaCode, и в GigaCode / GigaCode. Объекта
# `compact` с полями level/tokens_before/tokens_after нет ни в одном рантайме;
# прежняя версия читала именно его, поэтому compact_level всегда была "unknown",
# а ветка проверки целостности не выполнялась ни разу. Теперь роль «мы упёрлись
# в лимит, а не человек попросил» играет trigger=auto.
#
# ГРАНИЦА СРЕД. Отказ на PreCompact блокирует сжатие в GigaCode; в
# Qwen/GigaCode PreCompact не входит в список блокирующих событий, там тот же
# exit 2 деградирует до громкого предупреждения. Snapshot пишется в обоих
# случаях — это и есть основная ценность хука.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

SNAPSHOT_DIR=".gigacode/.context-snapshots"
mkdir -p "$SNAPSHOT_DIR"

TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
SNAPSHOT_FILE="$SNAPSHOT_DIR/$TIMESTAMP.json"

# === STEP 1: метаданные события ===
TRIGGER="$(hook_field '.trigger')"
[[ -n "$TRIGGER" ]] || TRIGGER="unknown"
SESSION_ID="$(hook_field '.session_id')"

# === STEP 2: gather protected state ===
RISK_CLASS=$(cat .gigacode/.cost/current-risk-class 2>/dev/null | tr -d '[:space:]' || echo "unknown")
[[ -n "$RISK_CLASS" ]] || RISK_CLASS="unknown"
ACTIVE_SDD=$(ls -t docs/sdd/*.md 2>/dev/null | head -1 || true)
[[ -n "$ACTIVE_SDD" ]] || ACTIVE_SDD="none"
EVIDENCE_BUNDLE_EXISTS="false"
[[ -f ".gigacode/evidence-bundle.json" ]] && EVIDENCE_BUNDLE_EXISTS="true"

# Pending failing tests — последняя строка из test runner cache, если есть.
LAST_TEST_STATUS="unknown"
if [[ -f ".gigacode/.cache/last-test-run.txt" ]]; then
  LAST_TEST_STATUS=$(tail -1 .gigacode/.cache/last-test-run.txt 2>/dev/null | tr -d '[:space:]' || echo "unknown")
  [[ -n "$LAST_TEST_STATUS" ]] || LAST_TEST_STATUS="unknown"
fi

# === STEP 3: write snapshot ===
# Через jq, а не heredoc: значения приходят из файлов и имени ветки, любая
# кавычка в них раньше давала битый JSON в самом снимке состояния.
jq -n \
  --arg ts "$TIMESTAMP" \
  --arg trigger "$TRIGGER" \
  --arg session "$SESSION_ID" \
  --arg rc "$RISK_CLASS" \
  --arg sdd "$ACTIVE_SDD" \
  --argjson bundle "$EVIDENCE_BUNDLE_EXISTS" \
  --arg tests "$LAST_TEST_STATUS" \
  '{
    timestamp: $ts,
    trigger: $trigger,
    session_id: $session,
    protected_state: {
      risk_class: $rc,
      active_sdd: $sdd,
      evidence_bundle_present: $bundle,
      last_test_status: $tests
    },
    pdlc_ref: "§2.10, §4.4"
  }' > "$SNAPSHOT_FILE"

# === STEP 4: integrity check ===
# Автосжатие с красными тестами — плохая идея: контекст того, что именно упало,
# уедет в summary. Ручное сжатие человек инициировал сам, ему не мешаем.
if [[ "$TRIGGER" == "auto" ]]; then
  if [[ "$LAST_TEST_STATUS" == "failed" || "$LAST_TEST_STATUS" == "red" ]]; then
    deny "Автосжатие контекста при падающих тестах (last_test_status=$LAST_TEST_STATUS). Snapshot сохранён в $SNAPSHOT_FILE. Почини тесты, запусти /evidence или сожми контекст вручную, осознанно приняв потерю контекста прогона. §2.10 PDLC v3.5."
  fi
fi

# Если SDD утерян из контекста, а risk class ≥ R3 — отказ.
if [[ "$RISK_CLASS" =~ ^R[3-5]$ ]] && [[ "$ACTIVE_SDD" == "none" ]]; then
  deny "Сжатие контекста при risk class $RISK_CLASS, но в docs/sdd/ нет активного SDD. Для R3+ SDD обязателен. Snapshot сохранён в $SNAPSHOT_FILE. §4.5 PDLC v3.5."
fi

echo "[context-integrity] Snapshot saved: $SNAPSHOT_FILE (trigger=$TRIGGER, risk=$RISK_CLASS)" >&2
exit 0
