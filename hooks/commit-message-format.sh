#!/usr/bin/env bash
# commit-message-format.sh — PreToolUse hook for Bash.
#
# Roadmap P2·06 (docs/plan/20260619-harness-cicd-integration-roadmap.md):
# превращает соглашение Conventional Commits (GIGACODE.md §2 Git) в жёсткий гейт.
#
# Contract:
#   - stdin: JSON event with .tool_input.command
#   - acts only on `git commit … -m <msg>`; everything else → exit 0 (noop)
#   - msg must match Conventional Commits:
#       <type>(<scope>)?!?: <subject>
#     type ∈ feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert
#   - invalid → {"decision":"block","reason":…} + exit 2
#   - non-extractable message (-F/--file, heredoc, no -m) → exit 0 (cannot judge,
#     do not block — false block costs more than a missed lint here)

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

# Only care about `git commit`.
printf '%s' "$COMMAND" | grep -qE '\bgit\s+commit\b' || exit 0

# Amend without -m (reuses old message), or message-from-file — cannot judge here.
printf '%s' "$COMMAND" | grep -qE '(-F|--file)\b' && exit 0

# Extract the first -m / --message argument (single- or double-quoted).
MSG="$(printf '%s' "$COMMAND" | sed -nE "s/.*(-m|--message)[[:space:]]+'([^']*)'.*/\2/p" | head -1)"
[ -z "$MSG" ] && MSG="$(printf '%s' "$COMMAND" | sed -nE 's/.*(-m|--message)[[:space:]]+"([^"]*)".*/\2/p' | head -1)"

# No extractable message (e.g. `git commit` opening an editor) → noop.
[ -z "$MSG" ] && exit 0

# Conventional Commits subject line.
CC_RE='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_.-]+\))?!?: .+'

if ! printf '%s' "$MSG" | grep -qE "$CC_RE"; then
  block "commit message не соответствует Conventional Commits (GIGACODE.md §2): \"$MSG\". Ожидается '<type>(<scope>): <subject>', type ∈ feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert. Пример: 'feat(hooks): add branch-naming gate'."
fi

exit 0
