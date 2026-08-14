#!/usr/bin/env bash
# Shared helpers for GigaCode hooks.
# Source this file from any hook: source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

set -euo pipefail

# jq обязателен: hook_field/block/emit_context держатся на нём. Без гейта хук
# падал бы с exit 127, а это для GigaCode «хук не сработал» — политика
# переставала применяться молча. См. lib/require-jq.sh.
source "${BASH_SOURCE[0]%/*}/require-jq.sh" || exit 2

# Read stdin (GigaCode passes JSON event payload to hooks via stdin).
# Caches input so multiple `get_*` calls don't drain stdin twice.
_HOOK_INPUT=""
hook_input() {
  if [[ -z "$_HOOK_INPUT" ]]; then
    _HOOK_INPUT=$(cat)
  fi
  printf '%s' "$_HOOK_INPUT"
}

# Extract a field from the hook input via jq.
# Usage: hook_field '.tool_input.command'
hook_field() {
  hook_input | jq -r "$1 // empty"
}

# Block the tool call with a structured reason. Exit code 2 signals hard block.
# Usage: block "reason text"
block() {
  local reason="$1"
  printf '{"decision":"block","reason":%s}\n' "$(jq -Rn --arg r "$reason" '$r')" >&2
  exit 2
}

# Emit additional context for UserPromptSubmit (non-blocking).
# Usage: emit_context "warning or hint"
emit_context() {
  local msg="$1"
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' \
    "$(jq -Rn --arg m "$msg" '$m')"
}

# Test whether a string matches any of the provided extended-regex patterns.
# Usage: matches_any "$value" "pattern1" "pattern2" ...
# Returns 0 on first match, 1 if no match.
matches_any() {
  local value="$1"; shift
  local pattern
  for pattern in "$@"; do
    if printf '%s' "$value" | grep -qE "$pattern"; then
      return 0
    fi
  done
  return 1
}
