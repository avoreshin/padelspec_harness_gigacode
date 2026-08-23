#!/usr/bin/env bash
# validate-schemas.sh — orchestrator для всех JSON Schemas обвязки.
#
# Source SDD: docs/sdd/20260520-schema-completeness.md (R1, approved 2026-05-20)
# (SDD живёт в рабочем репозитории pdlc-harness-work, сюда не бэкпортился)
# Canonical validator: ajv-cli@5 + ajv-formats@3 через npx (draft 2020-12).
#
# Подкоманды:
#   compile                 — ajv compile всех schemas (self-validation, INV-3)
#   validate <schema> <file> — провалидировать один файл одной schema
#   all                     — полный прогон по всем существующим артефактам + fixtures
#   --dry-run               — только показать, что будет проверено, без запуска
#
# Read-only по отношению к артефактам. Безопасный для R1.
# Exit-codes:
#   0 — all checks passed (green)
#   1 — at least one validation failed (red/yellow)
#   2 — usage / internal / tooling error

set -u

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2; exit 2
}
cd "$REPO_ROOT"

if [ -t 1 ]; then
  C_PINK=$'\033[0;35m'; C_CYAN=$'\033[0;36m'; C_YELLOW=$'\033[0;33m'
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_PINK=""; C_CYAN=""; C_YELLOW=""; C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
fi

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
SCHEMA_DIR="$HARNESS_ROOT/schemas"
FIXTURE_DIR="tests/fixtures"
SDD_DIR="docs/sdd"
DORA_DIR="docs/baseline"
RISK_LADDER="$HARNESS_ROOT/policies/risk-ladder.yaml"
AUDIT_GLOB=".gigacode/audit/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].jsonl"
EVIDENCE_FILE="docs/evidence/step0-evidence-bundle.json"

# Audit threshold (≥90% строк должны валидироваться per file)
AUDIT_THRESHOLD_PCT=90

PASS=0
FAIL=0
FAILED=()
DRY_RUN=false

ok()   { PASS=$((PASS+1));   printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"; }
info() { printf '  %s· %s%s\n' "$C_DIM" "$1" "$C_RESET"; }
section() { printf '\n%s%s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

# ---------------------------------------------------------------------------
# validator wrapper — uses scripts/_validator.js with cached ajv@8 + js-yaml@4
# in .gigacode/.cache/node/ (one-time npm install on first run).
# ---------------------------------------------------------------------------

VALIDATOR=(node "$HARNESS_ROOT/scripts/_validator.js")

# Create a temp file guaranteed to end in .json — ajv detects format by extension.
mk_json_tmp() {
  local base; base="$(mktemp -t harness-validate.XXXXXX)"
  mv "$base" "$base.json"
  printf '%s\n' "$base.json"
}

ajv_compile() {
  local schema="$1"
  if $DRY_RUN; then
    info "DRY: validator compile $schema"
    return 0
  fi
  "${VALIDATOR[@]}" compile "$schema" >/dev/null 2>&1
}

ajv_validate() {
  local schema="$1"; local file="$2"
  if $DRY_RUN; then
    info "DRY: validator validate -s $schema -d $file"
    return 0
  fi
  "${VALIDATOR[@]}" validate "$schema" "$file" >/dev/null 2>&1
}

# Returns 0 if at least AUDIT_THRESHOLD_PCT lines validate
ajv_validate_jsonl() {
  local schema="$1"; local file="$2"
  if $DRY_RUN; then
    info "DRY: validator jsonl $schema $file"
    return 0
  fi
  local result
  if ! result="$("${VALIDATOR[@]}" jsonl "$schema" "$file" 2>/dev/null)"; then
    err "$file: validator failed"
    return 1
  fi
  local passed total
  passed="${result%%/*}"
  total="${result##*/}"
  if [ "$total" -eq 0 ]; then
    return 0
  fi
  local pct=$((passed * 100 / total))
  if [ "$pct" -ge "$AUDIT_THRESHOLD_PCT" ]; then
    info "$file: $passed / $total lines pass (${pct}%)"
    return 0
  fi
  err "$file: only $passed / $total lines pass (${pct}%), threshold ${AUDIT_THRESHOLD_PCT}%"
  return 1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_compile() {
  section "Self-validation — compile each schema (INV-3)"
  local n=0
  for s in "$SCHEMA_DIR"/*.schema.json; do
    [ -e "$s" ] || continue
    n=$((n+1))
    if ajv_compile "$s"; then
      ok "compile: $s"
    else
      fail "compile: $s"
    fi
  done
  if [ "$n" -eq 0 ]; then
    fail "no schemas found in $SCHEMA_DIR/"
  fi
}

# Schema short-name → markdown extractor. Empty for schemas with no .md source.
extractor_for_schema() {
  case "$1" in
    sdd)            printf '%s\n' "$HARNESS_ROOT/scripts/extract-sdd-frontmatter.sh" ;;
    dora-baseline)  printf '%s\n' "$HARNESS_ROOT/scripts/extract-dora-frontmatter.sh" ;;
    *)              printf '\n' ;;
  esac
}

# Resolve schema argument (short-name OR literal path) → (path, short-name).
# Prints "<path>\t<short-name>" on success; returns 1 on miss.
resolve_schema() {
  local arg="$1"
  local path name
  if [ -f "$arg" ]; then
    path="$arg"
  elif [ -f "$SCHEMA_DIR/${arg}.schema.json" ]; then
    path="$SCHEMA_DIR/${arg}.schema.json"
  else
    return 1
  fi
  name="${path##*/}"
  name="${name%.schema.json}"
  printf '%s\t%s\n' "$path" "$name"
}

cmd_validate_one() {
  local schema_arg="${1:-}"; local file="${2:-}"
  [ -z "$schema_arg" ] || [ -z "$file" ] && { err "usage: validate <schema> <file>"; exit 2; }

  local resolved schema_path schema_name
  if ! resolved="$(resolve_schema "$schema_arg")"; then
    err "schema not found: $schema_arg (tried literal path and $SCHEMA_DIR/${schema_arg}.schema.json)"
    exit 2
  fi
  schema_path="${resolved%$'\t'*}"
  schema_name="${resolved#*$'\t'}"

  if [ ! -f "$file" ]; then
    err "file not found: $file"
    exit 2
  fi

  # Markdown source needs an extractor (frontmatter → JSON).
  local target="$file"
  local tmp=""
  if [[ "$file" == *.md ]]; then
    local extractor
    extractor="$(extractor_for_schema "$schema_name")"
    if [ -z "$extractor" ]; then
      err "schema $schema_name has no markdown extractor; supply JSON/YAML instead of $file"
      exit 2
    fi
    if [ ! -x "$extractor" ]; then
      err "extractor missing or not executable: $extractor"
      exit 2
    fi
    tmp="$(mk_json_tmp)"
    if ! "$extractor" "$file" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      fail "extractor failed for $file"
      return
    fi
    target="$tmp"
  fi

  if ajv_validate "$schema_path" "$target"; then
    ok "$file conforms to $schema_name"
  else
    fail "$file does NOT conform to $schema_name"
  fi
  [ -n "$tmp" ] && rm -f "$tmp"
}

cmd_all() {
  cmd_compile

  # AC-5: backward-compat — existing evidence-bundle.schema.json + step0 evidence
  section "AC-5: evidence-bundle backward-compat (existing)"
  if [ -f "$EVIDENCE_FILE" ] && [ -f "$SCHEMA_DIR/evidence-bundle.schema.json" ]; then
    if ajv_validate "$SCHEMA_DIR/evidence-bundle.schema.json" "$EVIDENCE_FILE"; then
      ok "evidence-bundle still valid: $EVIDENCE_FILE"
    else
      fail "evidence-bundle backward-compat BROKEN: $EVIDENCE_FILE"
    fi
  else
    info "skipping (file missing): $EVIDENCE_FILE"
  fi

  # AC-1: SDD
  section "AC-1: sdd.schema.json against all docs/sdd/*.md"
  local sdd_schema="$SCHEMA_DIR/sdd.schema.json"
  if [ ! -f "$sdd_schema" ]; then
    fail "missing: $sdd_schema"
  else
    for sdd in "$SDD_DIR"/*.md; do
      [ -e "$sdd" ] || continue
      local tmp; tmp="$(mk_json_tmp)"
      if [ -x $HARNESS_ROOT/scripts/extract-sdd-frontmatter.sh ] \
         && $HARNESS_ROOT/scripts/extract-sdd-frontmatter.sh "$sdd" > "$tmp" 2>/dev/null; then
        if ajv_validate "$sdd_schema" "$tmp"; then
          ok "SDD valid: $sdd"
        else
          fail "SDD invalid: $sdd"
        fi
      else
        fail "extractor missing or failed: $sdd"
      fi
      rm -f "$tmp"
    done
  fi

  # AC-2: DORA baseline
  section "AC-2: dora-baseline.schema.json against docs/baseline/dora-*.md"
  local dora_schema="$SCHEMA_DIR/dora-baseline.schema.json"
  if [ ! -f "$dora_schema" ]; then
    fail "missing: $dora_schema"
  else
    for b in "$DORA_DIR"/dora-*.md; do
      [ -e "$b" ] || continue
      local tmp; tmp="$(mk_json_tmp)"
      if [ -x $HARNESS_ROOT/scripts/extract-dora-frontmatter.sh ] \
         && $HARNESS_ROOT/scripts/extract-dora-frontmatter.sh "$b" > "$tmp" 2>/dev/null; then
        if ajv_validate "$dora_schema" "$tmp"; then
          ok "baseline valid: $b"
        else
          fail "baseline invalid: $b"
        fi
      else
        fail "extractor missing or failed: $b"
      fi
      rm -f "$tmp"
    done
  fi

  # AC-3: risk-ladder
  section "AC-3: risk-ladder.schema.json against $HARNESS_ROOT/policies/risk-ladder.yaml"
  local rl_schema="$SCHEMA_DIR/risk-ladder.schema.json"
  if [ ! -f "$rl_schema" ]; then
    fail "missing: $rl_schema"
  elif [ ! -f "$RISK_LADDER" ]; then
    info "skipping (yaml missing): $RISK_LADDER"
  else
    # _validator.js reads YAML natively via js-yaml — no temp conversion needed.
    if ajv_validate "$rl_schema" "$RISK_LADDER"; then
      ok "risk-ladder.yaml valid"
    else
      fail "risk-ladder.yaml invalid"
    fi
  fi

  # AC-4: audit JSONL
  section "AC-4: audit-event.schema.json against .gigacode/audit/*.jsonl (≥${AUDIT_THRESHOLD_PCT}% per file)"
  local ae_schema="$SCHEMA_DIR/audit-event.schema.json"
  if [ ! -f "$ae_schema" ]; then
    fail "missing: $ae_schema"
  else
    local found=0
    for f in $AUDIT_GLOB; do
      [ -e "$f" ] || continue
      found=$((found+1))
      if ajv_validate_jsonl "$ae_schema" "$f"; then
        ok "audit ok: $f"
      else
        fail "audit fails threshold: $f"
      fi
    done
    if [ "$found" -eq 0 ]; then
      info "no audit files matched $AUDIT_GLOB"
    fi
  fi

  # Negative fixtures (should FAIL validation; we count it as PASS if they fail correctly)
  section "Negative fixtures — must FAIL validation (correctness check)"
  if [ -d "$FIXTURE_DIR" ]; then
    # SDD invalid
    local fx="$FIXTURE_DIR/sdd-invalid-missing-ac.md"
    if [ -f "$fx" ] && [ -f "$sdd_schema" ] && [ -x $HARNESS_ROOT/scripts/extract-sdd-frontmatter.sh ]; then
      local tmp; tmp="$(mk_json_tmp)"
      $HARNESS_ROOT/scripts/extract-sdd-frontmatter.sh "$fx" > "$tmp" 2>/dev/null || true
      if ajv_validate "$sdd_schema" "$tmp"; then
        fail "negative fixture wrongly passed: $fx"
      else
        ok "negative fixture correctly rejected: $fx"
      fi
      rm -f "$tmp"
    else
      info "skipping fixture: sdd-invalid-missing-ac (file/extractor/schema absent)"
    fi

    # DORA invalid
    fx="$FIXTURE_DIR/dora-invalid-missing-flag.md"
    if [ -f "$fx" ] && [ -f "$dora_schema" ] && [ -x $HARNESS_ROOT/scripts/extract-dora-frontmatter.sh ]; then
      local tmp; tmp="$(mk_json_tmp)"
      $HARNESS_ROOT/scripts/extract-dora-frontmatter.sh "$fx" > "$tmp" 2>/dev/null || true
      if ajv_validate "$dora_schema" "$tmp"; then
        fail "negative fixture wrongly passed: $fx"
      else
        ok "negative fixture correctly rejected: $fx"
      fi
      rm -f "$tmp"
    fi

    # Audit invalid
    fx="$FIXTURE_DIR/audit-event-invalid-missing-timestamp.jsonl"
    if [ -f "$fx" ] && [ -f "$ae_schema" ]; then
      if ajv_validate "$ae_schema" "$fx"; then
        fail "negative fixture wrongly passed: $fx"
      else
        ok "negative fixture correctly rejected: $fx"
      fi
    fi
  else
    info "no $FIXTURE_DIR/ — skipping negative tests"
  fi
}

usage() {
  cat >&2 <<EOF
usage: validate-schemas.sh <command> [args]

commands:
  compile                     Self-validate each schema in $HARNESS_ROOT/schemas/
  validate <schema> <file>    Validate one file against one schema
  all                         Full run: all schemas × all artifacts × fixtures
  -h | --help                 Show this help

flags:
  --dry-run                   Print actions, do not run ajv

env defaults:
  AUDIT_THRESHOLD_PCT = $AUDIT_THRESHOLD_PCT
EOF
  exit 2
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

[ $# -lt 1 ] && usage

# Pre-process global flags
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *)         ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
[ $# -lt 1 ] && usage

cmd="$1"; shift
printf '%sschema validator%s %s(SDD-20260520-schema-completeness, R1)%s\n' \
  "$C_GREEN" "$C_RESET" "$C_DIM" "$C_RESET"
$DRY_RUN && printf '%s(dry-run mode — no ajv invocations)%s\n' "$C_YELLOW" "$C_RESET"

case "$cmd" in
  compile)  cmd_compile ;;
  validate) cmd_validate_one "$@" ;;
  all)      cmd_all ;;
  -h|--help|help) usage ;;
  *) err "unknown command: $cmd"; usage ;;
esac

printf '\n%sSummary:%s %s%d passed%s, %s%d failed%s\n' \
  "$C_YELLOW" "$C_RESET" "$C_GREEN" "$PASS" "$C_RESET" "$C_RED" "$FAIL" "$C_RESET"

if [ "$FAIL" -gt 0 ]; then
  printf '\n%sFailed:%s\n' "$C_RED" "$C_RESET"
  for c in "${FAILED[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
exit 0
