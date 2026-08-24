#!/usr/bin/env bash
# init-project.sh
# Drop pdlc-harness into a target repo: copy .gigacode/, fill GIGACODE.md
# placeholders, scaffold docs/, smoke-test one hook.
#
# Usage:
#   init-project.sh [--target PATH] [--stack STACK] [--framework FW] \
#                   [--r3-domains "auth,payments"] [--owner TEAM] [--force]
#
# All flags optional. Missing values stay as placeholders that the
# SessionStart hook will flag later.
#
# Source of harness: either $PDLC_HARNESS_SRC env, or the directory
# that contains this script (../../  → repo root).

set -euo pipefail

# --- arg parsing ---
TARGET="$PWD"
STACK=""
FRAMEWORK=""
R3_DOMAINS=""
OWNER=""
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --framework) FRAMEWORK="$2"; shift 2 ;;
    --r3-domains) R3_DOMAINS="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# --- locate harness source ---
if [[ -n "${PDLC_HARNESS_SRC:-}" ]]; then
  SRC="$PDLC_HARNESS_SRC"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

if [[ ! -d "$SRC/.gigacode" ]]; then
  echo "[init-project] cannot find harness source at $SRC/.gigacode" >&2
  echo "Set PDLC_HARNESS_SRC or run from a checkout of pdlc-harness." >&2
  exit 1
fi

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
echo "[init-project] source: $SRC"
echo "[init-project] target: $TARGET"

# --- safety: refuse to overwrite existing .gigacode/ unless --force ---
if [[ -d "$TARGET/.gigacode" && "$FORCE" -ne 1 ]]; then
  echo "[init-project] $TARGET/.gigacode already exists. Re-run with --force to overwrite." >&2
  exit 3
fi

# --- copy .gigacode/ ---
echo "[init-project] copying harness..."
rm -rf "$TARGET/.gigacode.bak" 2>/dev/null || true
if [[ -d "$TARGET/.gigacode" ]]; then
  mv "$TARGET/.gigacode" "$TARGET/.gigacode.bak"
  echo "[init-project] previous .gigacode/ moved to .gigacode.bak"
fi
# rsync preserves perms (hooks must stay executable). Fallback to cp -R.
if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --exclude='.git' --exclude='.DS_Store' \
    --exclude='audit/' --exclude='.context-snapshots/' --exclude='.cost/' \
    --exclude='settings.local.json' --exclude='evidence-bundle*.json' \
    "$SRC/.gigacode/" "$TARGET/.gigacode/"
else
  cp -R "$SRC/.gigacode" "$TARGET/"
  find "$TARGET/.gigacode" -name ".DS_Store" -delete 2>/dev/null || true
  rm -rf "$TARGET/.gigacode/audit" "$TARGET/.gigacode/.context-snapshots" "$TARGET/.gigacode/.cost" 2>/dev/null || true
  rm -f "$TARGET/.gigacode/settings.local.json" "$TARGET/.gigacode"/evidence-bundle*.json 2>/dev/null || true
fi

# --- ensure hooks are executable ---
chmod +x "$TARGET/.gigacode/hooks/"*.sh 2>/dev/null || true
chmod +x "$TARGET/.gigacode/scripts/"*.sh 2>/dev/null || true

# --- fill GIGACODE.md placeholders ---
GIGACODE_MD="$TARGET/.gigacode/GIGACODE.md"
if [[ -f "$GIGACODE_MD" ]]; then
  fill() {
    local pattern="$1" value="$2"
    [[ -z "$value" ]] && return 0
    # Escape the value for sed replacement (& and \).
    local escaped=${value//\\/\\\\}
    escaped=${escaped//\&/\\&}
    escaped=${escaped//|/\\|}
    sed -i.bak -E "s|$pattern|$escaped|" "$GIGACODE_MD"
  }
  fill '<язык, фреймворк, runtime>' "${STACK:-}${FRAMEWORK:+, $FRAMEWORK}"
  fill '<monolith / microservices / modular>' ""  # let user fill
  fill '<auth, payments, PII — список доменов R3\+>' "${R3_DOMAINS}"
  fill '<команда / роль>' "${OWNER}"
  fill '<YYYY-MM-DD>' "$(date +%Y-%m-%d)"
  rm -f "$GIGACODE_MD.bak"
fi

# --- scaffold docs ---
mkdir -p "$TARGET/docs/sdd" "$TARGET/docs/adr"
[[ -f "$TARGET/docs/adr/0001-pilot-scope.md" ]] || cat > "$TARGET/docs/adr/0001-pilot-scope.md" <<'ADR'
# ADR-0001: Pilot scope

* Status: proposed
* Date: __TODO__

## Context

This repo adopts the pdlc-harness on __DATE__. Defines what is in scope
for the 90-day MVP gate (see harness IMPLEMENTATION_PLAN §1).

## Decision

__TODO__: list the pilot team, the first feature, and the risk class
boundary for autonomous work.

## Consequences

__TODO__
ADR

# --- minimal .gitignore additions ---
GI="$TARGET/.gitignore"
touch "$GI"
add_ignore() {
  local rule="$1"
  if ! grep -qxF "$rule" "$GI" 2>/dev/null; then
    echo "$rule" >> "$GI"
  fi
}
add_ignore "# pdlc-harness runtime artefacts"
add_ignore ".gigacode/audit/"
add_ignore ".gigacode/.context-snapshots/"
add_ignore ".gigacode/.cost/"
add_ignore ".gigacode/settings.local.json"
add_ignore ".gigacode/evidence-bundle.json"
add_ignore ".gigacode/evidence-bundle.draft.json"
# транзиентный снапшот скилла find-dev-metrics: перезаписывается при каждом
# запуске /find-metrics и в истории не нужен
add_ignore ".dev-metrics-scan.json"

# --- smoke-test: destructive-command-blocker should refuse rm -rf / ---
SMOKE_HOOK="$TARGET/.gigacode/hooks/destructive-command-blocker.sh"
SMOKE_OK="unknown"
if [[ -x "$SMOKE_HOOK" ]]; then
  PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  if echo "$PAYLOAD" | "$SMOKE_HOOK" >/dev/null 2>&1; then
    SMOKE_OK="FAIL (hook should have blocked)"
  else
    SMOKE_OK="PASS (rm -rf / correctly blocked)"
  fi
fi

# --- final placeholder audit ---
if [[ -x "$TARGET/.gigacode/hooks/gigacode-md-placeholders.sh" ]]; then
  ( cd "$TARGET" && bash .gigacode/hooks/gigacode-md-placeholders.sh 2>&1 ) || true
fi

# --- report ---
echo ""
echo "=== pdlc-harness installed at $TARGET ==="
echo "  .gigacode/         copied ($(find "$TARGET/.gigacode" -type f | wc -l | tr -d ' ') files)"
echo "  GIGACODE.md        ${STACK:+stack=$STACK }${FRAMEWORK:+fw=$FRAMEWORK }${R3_DOMAINS:+r3=$R3_DOMAINS }${OWNER:+owner=$OWNER}"
echo "  docs/sdd/        created"
echo "  docs/adr/        created (ADR-0001 stub)"
echo "  .gitignore       runtime artefacts added"
echo "  smoke test:      $SMOKE_OK"
echo ""
echo "Next steps:"
echo "  1. Open .gigacode/GIGACODE.md and fill any remaining <...> placeholders."
echo "  2. Edit docs/adr/0001-pilot-scope.md."
echo "  3. Run: /sdd-new <your first feature>"
