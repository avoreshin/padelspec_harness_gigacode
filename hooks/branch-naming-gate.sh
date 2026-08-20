#!/usr/bin/env bash
# branch-naming-gate.sh — PreToolUse hook for Bash.
#
# Roadmap P2·06 (docs/plan/20260619-harness-cicd-integration-roadmap.md):
# branch hygiene как детерминированный гейт. Согласуется с release-process.md
# (feat/ · fix/ · hotfix/ · release/) и worktree-веток agent/<task-id>.
#
# Contract:
#   - stdin: JSON event with .tool_input.command
#   - acts only on branch CREATION:
#       git checkout -b <name> | git switch -c <name> | git branch <name>
#   - skips deletions/listing (-d, -D, -a, -r, --list, --delete, etc.)
#   - <name> must match: ^(feat|fix|docs|chore|refactor|test|perf|hotfix|release|agent)/…
#     or be a base branch (main|master|develop|trunk)
#   - invalid → {"decision":"block","reason":…} + exit 2

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

# Must be a git branch-creating command.
printf '%s' "$COMMAND" | grep -qE '\bgit\s+(checkout\s+-b|switch\s+-c|branch)\b' || exit 0

# Skip branch deletion / listing flags — those are not creation.
printf '%s' "$COMMAND" | grep -qE '\bgit\s+branch\s+.*(-d|-D|--delete|--list|-a|-r|--all|--remotes|--merged|--no-merged)\b' && exit 0

# Extract the branch name (first non-flag token after the create verb).
NAME="$(printf '%s' "$COMMAND" | sed -nE 's/.*git[[:space:]]+(checkout[[:space:]]+-b|switch[[:space:]]+-c|branch)[[:space:]]+([^[:space:];|&]+).*/\2/p' | head -1)"

# Could not parse a name → noop (don't block ambiguous commands).
[ -z "$NAME" ] && exit 0
# A flag slipped through as the name (e.g. `git branch --show-current`) → noop.
case "$NAME" in -*) exit 0 ;; esac

ALLOWED='^(feat|fix|docs|chore|refactor|test|perf|hotfix|release|agent)/[a-z0-9._/-]+$'
BASE='^(main|master|develop|trunk)$'

if ! printf '%s' "$NAME" | grep -qE "$ALLOWED" && ! printf '%s' "$NAME" | grep -qE "$BASE"; then
  block "branch name '$NAME' нарушает конвенцию (release-process.md). Используй префикс: feat/ · fix/ · docs/ · chore/ · refactor/ · test/ · perf/ · hotfix/ · release/ · agent/. Пример: 'feat/sonarqube-mcp'."
fi

exit 0
