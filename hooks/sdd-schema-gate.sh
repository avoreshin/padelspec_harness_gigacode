#!/usr/bin/env bash
# sdd-schema-gate.sh — PostToolUse hook for Write|Edit|MultiEdit.
#
# Source: BL-006 (docs/plan/BACKLOG.md — рабочий репозиторий pdlc-harness-work).
# Closes the gap surfaced by BL-005:
# point-validation exists (.gigacode/scripts/validate-schemas.sh validate sdd <file>),
# but nothing dispatches it automatically on SDD edits. This hook does.
#
# Contract:
#   - stdin: JSON event from GigaCode with tool_input.file_path
#   - if file_path does not look like docs/sdd/*.md → exit 0 (noop)
#   - if file_path is an SDD → run validate-schemas.sh; exit 0 on pass,
#     emit {"decision":"block","reason":"..."} and exit 2 on fail
#   - missing validator cache / missing extractor → exit 0 with a warn line
#     (do not block author who has not run install-harness.sh yet)
#
# Intentionally non-strict on infra problems and strict on schema problems:
# the cost of a false block is higher than the cost of letting a malformed
# SDD slip past a not-yet-installed harness.
#
# ГРАНИЦА СРЕД. PostToolUse входит в список блокирующих событий GigaCode /
# GigaCode — там отказ действительно останавливает запись. В GigaCode это
# событие блокировку игнорирует: запись уже произошла, и агент получает лишь
# причину. Смысл хука сохраняется в обоих случаях (агент узнаёт о невалидном
# SDD сразу), но обещать блокировку в GigaCode нельзя.

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

INPUT="$(cat 2>/dev/null || true)"
[ -z "$INPUT" ] && exit 0

# jq is best-effort; if absent, fall back to grep on the JSON.
if command -v jq >/dev/null 2>&1; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""')
else
  FILE_PATH=$(printf '%s' "$INPUT" \
    | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
fi

[ -z "$FILE_PATH" ] && exit 0

# Only act on real SDD files under docs/sdd/, ignoring templates and underscores.
case "$FILE_PATH" in
  docs/sdd/_*.md|docs/sdd/*template*.md)
    exit 0
    ;;
  docs/sdd/*.md|*/docs/sdd/*.md)
    ;;
  *)
    exit 0
    ;;
esac

# Resolve relative path; if file does not exist (write that was cancelled),
# silently skip — nothing to validate.
[ -f "$FILE_PATH" ] || exit 0

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)}"
VALIDATOR="$HARNESS_ROOT/scripts/validate-schemas.sh"
if [ ! -x "$VALIDATOR" ]; then
  printf 'sdd-schema-gate: validator missing (%s); skipping. Ensure Node.js is installed and chmod +x .gigacode/scripts/*.sh\n' "$VALIDATOR" >&2
  exit 0
fi

# Run pointwise validation. Capture full output so a useful reason can travel
# back to the agent.
RAW_OUTPUT="$("$VALIDATOR" validate sdd "$FILE_PATH" 2>&1)"
EXIT_CODE=$?

if [ "$EXIT_CODE" -eq 0 ]; then
  exit 0
fi

# Distinguish "infra/tooling problem" (do not block) from "schema mismatch" (block).
# The script prints "does NOT conform" on real schema fails; anything else
# (file not found, schema missing, extractor crash) is infra.
if printf '%s' "$RAW_OUTPUT" | grep -q "does NOT conform"; then
  REASON=$(printf '%s' "$RAW_OUTPUT" | grep -E "does NOT conform|^error:" | head -3 | tr '\n' ' ')
  MSG="SDD schema mismatch on $FILE_PATH. $REASON Fix the SDD frontmatter (metadata, AC, INV, risk class, DoD) or use /sdd-new for revision."
  # Решение печатается в stdout — только его рантаймы разбирают как JSON.
  # Значение "deny", а не "block": "block" не распознаёт ни GigaCode, ни Qwen.
  # jq здесь может отсутствовать (у хука рабочий grep-fallback), поэтому объект
  # собирается им только при наличии; иначе несём причину через stderr + exit 2.
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$MSG" '{decision:"deny",reason:$r,hookSpecificOutput:{hookEventName:"PostToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  fi
  printf '%s\n' "$MSG" >&2
  exit 2
fi

# Infra failure — emit a warning and let the write through.
printf 'sdd-schema-gate: validator failed for non-schema reason on %s — letting through:\n%s\n' \
  "$FILE_PATH" "$RAW_OUTPUT" >&2
exit 0
