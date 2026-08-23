#!/usr/bin/env bash
# evidence-bundle-enforcer.sh (v2 — schema-aware)
# Stop hook: блокирует завершение сессии, если evidence bundle отсутствует
# или не соответствует schemas/evidence-bundle.schema.json.
# Согласно §2.13 + §4.4 PDLC v3.5.
#
# Стратегия валидации (по приоритету):
#   1. scripts/_validator.js — ajv@8 из локального кэша .gigacode/.cache/node/
#   2. python3 + jsonschema  — fallback на хостах без node
#   3. jq минимальный smoke  — last-resort: проверяем required-поля
#
# Если ни один валидатор недоступен и risk_class ≥ R3 — block.
# Это сознательно: для high-risk нельзя «доверять отсутствию проверки».
#
# v3: убран `npx --yes -p ajv-cli -p ajv-formats`. Он дёргался на КАЖДОМ Stop:
# при холодном кэше это загрузка пакетов по сети и десятки секунд на закрытие
# сессии, а без сети — ненулевой код, который прежняя ветка трактовала как
# «bundle не прошёл схему» и блокировала закрытие валидного bundle. Рядом всё
# это время лежал _validator.js с тем же ajv@8 в постоянном кэше и с точными
# кодами возврата: 1 — не сошлась схема, 2 — валидатор не смог запуститься.
# Различать эти два случая и требовалось.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

cd_harness_root

# Уже идёт повтор, вызванный этим же хуком: агент получил причину и снова
# остановился. Блокировать второй раз — значит зациклить сессию на одном и том
# же требовании, не дав человеку вмешаться.
if [[ "$(hook_field '.stop_hook_active')" == "true" ]]; then
  echo "[evidence-bundle-enforcer] повторный проход (stop_hook_active) — не блокируем" >&2
  exit 0
fi

BUNDLE_PATH="${EVIDENCE_BUNDLE_PATH:-.gigacode/evidence-bundle.json}"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
SCHEMA_PATH="${EVIDENCE_SCHEMA_PATH:-$HARNESS_ROOT/schemas/evidence-bundle.schema.json}"

# Раньше reason подставлялся в JSON сырым: любая кавычка или перевод строки из
# вывода валидатора давали битый объект. Экранирование теперь в deny().
emit_block() { deny "$1"; }

# === STEP 0: skip discussion-only sessions (no diff = no bundle) ===
# Lets R0 chat sessions close cleanly without forcing a stub bundle.
# Override with EVIDENCE_REQUIRED=1 if you want bundles for everything.
if [[ "${EVIDENCE_REQUIRED:-0}" != "1" ]] \
   && command -v git >/dev/null 2>&1 \
   && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STAGED=$(git diff --cached --name-only 2>/dev/null)
  UNSTAGED=$(git diff --name-only 2>/dev/null)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  if [[ -z "$STAGED$UNSTAGED$UNTRACKED" ]]; then
    echo "[evidence-bundle-enforcer] no file changes detected — skipping bundle requirement (R0 discussion session)" >&2
    exit 0
  fi
fi

# === STEP 1: файл существует ===
if [[ ! -f "$BUNDLE_PATH" ]]; then
  emit_block "Evidence bundle not found at $BUNDLE_PATH. Run /evidence to generate it. §2.13 PDLC v3.5."
fi

if [[ ! -f "$SCHEMA_PATH" ]]; then
  emit_block "Schema not found at $SCHEMA_PATH. Cannot validate evidence bundle without source of truth."
fi

# === STEP 2: bundle — валидный JSON ===
if ! jq empty "$BUNDLE_PATH" 2>/dev/null; then
  emit_block "Evidence bundle is not valid JSON: $BUNDLE_PATH"
fi

# === STEP 3: extract risk_class для условной логики ===
RISK_CLASS=$(jq -r '.risk_class // "unknown"' "$BUNDLE_PATH")
if ! [[ "$RISK_CLASS" =~ ^R[0-5]$ ]]; then
  emit_block "Evidence bundle has invalid or missing risk_class: '$RISK_CLASS'. Must be R0..R5."
fi

# === STEP 4: schema validation ===
VALIDATED=0
VALIDATION_OUTPUT=""

# 4a — _validator.js (ajv@8 из локального кэша, без сети)
VALIDATOR_JS=".gigacode/scripts/_validator.js"
if command -v node >/dev/null 2>&1 && [[ -f "$VALIDATOR_JS" ]]; then
  VALIDATION_OUTPUT="$(node "$VALIDATOR_JS" validate "$SCHEMA_PATH" "$BUNDLE_PATH" 2>&1)"
  VALIDATOR_RC=$?
  case "$VALIDATOR_RC" in
    0) VALIDATED=1 ;;
    1) emit_block "Evidence bundle failed schema validation. $VALIDATION_OUTPUT" ;;
    *)
      # Валидатор не смог запуститься (нет кэша ajv, нет сети для первой
      # установки, сломанный node). Это проблема инфраструктуры, а не bundle:
      # падать здесь — значит блокировать закрытие валидной сессии. Отдаём
      # решение следующим стратегиям.
      echo "[evidence-bundle-enforcer] _validator.js не отработал (rc=$VALIDATOR_RC), пробуем fallback: $VALIDATION_OUTPUT" >&2
      ;;
  esac
fi

# 4b — python jsonschema (fallback)
if [[ "$VALIDATED" -eq 0 ]] && command -v python3 >/dev/null 2>&1; then
  if python3 -c "import jsonschema" 2>/dev/null; then
    # PYTHONUTF8=1 (PEP 540) + явный encoding: bundle и схемы всегда UTF-8, а на
    # Windows с cp1251-локалью open() по умолчанию берёт кодировку локали и падает
    # на любом символе вне cp1251 (эмодзи, типографские кавычки) — до валидации.
    # Без этого хук отдаёт emit_block «failed schema validation» на валидном bundle.
    if VALIDATION_OUTPUT=$(PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python3 - <<PY 2>&1
import json, sys
from jsonschema import Draft202012Validator
schema = json.load(open("$SCHEMA_PATH", encoding="utf-8"))
data   = json.load(open("$BUNDLE_PATH", encoding="utf-8"))
v = Draft202012Validator(schema)
errs = sorted(v.iter_errors(data), key=lambda e: e.path)
if errs:
    for e in errs:
        path = "/".join(map(str, e.path)) or "<root>"
        print(f"{path}: {e.message}")
    sys.exit(1)
sys.exit(0)
PY
); then
      VALIDATED=1
    else
      emit_block "Evidence bundle failed schema validation (python jsonschema). Errors: $VALIDATION_OUTPUT"
    fi
  fi
fi

# 4c — last-resort smoke check (только required top-level + R-class rules)
if [[ "$VALIDATED" -eq 0 ]]; then
  # Если высокий R и валидатор недоступен — отказываем явно.
  if [[ "$RISK_CLASS" =~ ^R[3-5]$ ]]; then
    emit_block "No schema validator available (ajv / python jsonschema), and risk_class=$RISK_CLASS requires full validation. Install one: 'npm i -g ajv-cli ajv-formats' or 'pip install jsonschema'."
  fi
  # Для R0-R2 — минимальный smoke
  for field in schema_version task_id risk_class sdd_reference diff_summary tests completed_at; do
    if ! jq -e ".$field" "$BUNDLE_PATH" >/dev/null 2>&1; then
      emit_block "Evidence bundle missing required field: $field (smoke validation; install ajv for full schema check)."
    fi
  done
fi

# === STEP 5: семантические проверки сверх схемы ===
TESTS_STATUS=$(jq -r '.tests.status // "unknown"' "$BUNDLE_PATH")
if [[ "$TESTS_STATUS" != "passed" ]]; then
  emit_block "Evidence bundle reports tests.status=$TESTS_STATUS. Tasks cannot complete with non-passing tests."
fi

# 5a — sdd_reference must point to a real file (or be a conversation:// stub for R0)
SDD_REF=$(jq -r '.sdd_reference // ""' "$BUNDLE_PATH")
if [[ -z "$SDD_REF" ]]; then
  emit_block "Evidence bundle missing sdd_reference."
elif [[ "$SDD_REF" =~ ^conversation:// ]]; then
  if [[ "$RISK_CLASS" != "R0" ]]; then
    emit_block "sdd_reference=conversation://... is only valid for R0. Got risk_class=$RISK_CLASS."
  fi
elif [[ ! -f "$SDD_REF" ]]; then
  emit_block "sdd_reference points to '$SDD_REF' but that file does not exist."
fi

# 5b — diff_summary.files_changed must match reality (only when in a git repo)
# Exclude harness artefacts themselves: the bundle and its draft sibling.
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  CLAIMED=$(jq -r '.diff_summary.files_changed // 0' "$BUNDLE_PATH")
  BUNDLE_DRAFT="${BUNDLE_PATH%.json}.draft.json"
  # grep -v returns non-zero when nothing matches → would kill pipefail. Disable locally.
  set +o pipefail
  ACTUAL=$( { git diff --cached --name-only; git diff --name-only; git ls-files --others --exclude-standard; } 2>/dev/null \
    | sort -u | sed '/^$/d' \
    | grep -vxF "$BUNDLE_PATH" \
    | grep -vxF "$BUNDLE_DRAFT" \
    | wc -l | tr -d ' ')
  set -o pipefail
  if [[ "$ACTUAL" != "$CLAIMED" ]]; then
    emit_block "diff_summary.files_changed=$CLAIMED does not match git ($ACTUAL actual files, excluding bundle artefacts). Bundle is lying about scope."
  fi
fi

# Проверка соответствия audit_depth и risk_class (§4.5).
case "$RISK_CLASS" in
  R3|R4|R5)
    SECURITY_VERDICT=$(jq -r '.security_verdict.verdict // "MISSING"' "$BUNDLE_PATH")
    if [[ "$SECURITY_VERDICT" != "PASS" ]]; then
      emit_block "Risk class $RISK_CLASS requires security_verdict.verdict=PASS. Got: $SECURITY_VERDICT. §4.5 PDLC v3.5."
    fi
    ;;
esac

case "$RISK_CLASS" in
  R4|R5)
    APPROVER=$(jq -r '.human_signoff.approver // ""' "$BUNDLE_PATH")
    if [[ -z "$APPROVER" ]]; then
      emit_block "Risk class $RISK_CLASS requires human_signoff.approver. §4.5 (separation of duties)."
    fi
    AUTHOR=$(jq -r '.human_signoff.separation_of_duties_proof.author // ""' "$BUNDLE_PATH")
    REVIEWER=$(jq -r '.human_signoff.separation_of_duties_proof.reviewer // ""' "$BUNDLE_PATH")
    DEPLOYER=$(jq -r '.human_signoff.separation_of_duties_proof.deployer // ""' "$BUNDLE_PATH")
    if [[ -z "$AUTHOR" || -z "$REVIEWER" || -z "$DEPLOYER" ]]; then
      emit_block "R$RISK_CLASS requires separation_of_duties_proof with author/reviewer/deployer all set."
    fi
    if [[ "$AUTHOR" == "$REVIEWER" || "$REVIEWER" == "$DEPLOYER" || "$AUTHOR" == "$DEPLOYER" ]]; then
      emit_block "R$RISK_CLASS separation of duties violated: author/reviewer/deployer must be three distinct people. Got: author=$AUTHOR reviewer=$REVIEWER deployer=$DEPLOYER"
    fi
    ;;
esac

if [[ "$RISK_CLASS" == "R5" ]]; then
  CAB_DECISION=$(jq -r '.cab_decision.decision // "MISSING"' "$BUNDLE_PATH")
  if [[ "$CAB_DECISION" != "approved" && "$CAB_DECISION" != "approved_with_conditions" ]]; then
    emit_block "R5 requires cab_decision.decision in [approved, approved_with_conditions]. Got: $CAB_DECISION"
  fi
  REG_STATUS=$(jq -r '.regulatory_eval_results.status // "MISSING"' "$BUNDLE_PATH")
  if [[ "$REG_STATUS" != "passed" ]]; then
    emit_block "R5 requires regulatory_eval_results.status=passed. Got: $REG_STATUS"
  fi
fi

echo "[evidence-bundle-enforcer] $BUNDLE_PATH validated for risk_class=$RISK_CLASS" >&2
exit 0
