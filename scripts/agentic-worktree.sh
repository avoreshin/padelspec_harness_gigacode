#!/usr/bin/env bash
# agentic-worktree.sh — управляет per-task git worktrees для Coding subagent.
#
# Часть обвязки AI DISRUPT PDLC v3.5:
#   - Coding agent (.gigacode/agents/coding.md) и R2+ задачи работают в
#     .worktrees/<task-id>/, а не на основном checkout.
#   - Параллельные агентные задачи живут в отдельных worktree.
#   - После accepted evidence bundle — worktree удаляется командой `finish`.
#
# Документация паттерна: harness-docs/docs/WORKTREE-PATTERN.md
#
# Использование:
#   scripts/agentic-worktree.sh start <task-id> [--from <base-ref>]
#   scripts/agentic-worktree.sh finish <task-id> [--keep-branch]
#   scripts/agentic-worktree.sh list
#   scripts/agentic-worktree.sh prune [--dry-run]
#   scripts/agentic-worktree.sh path <task-id>
#
# task-id — kebab-case slug, обычно совпадает с SDD slug или ticket key.
# Worktree-каталог: .worktrees/<task-id>
# Branch: agent/<task-id>
# Read-only, идемпотентно. Не модифицирует main checkout.
# Exit codes:
#   0 — success
#   1 — invalid arguments / task-id
#   2 — git state error (uncommitted changes, missing base ref, etc.)
#   3 — runtime error (filesystem, git worktree command failure)

set -u

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 2
}
cd "$REPO_ROOT"

WORKTREE_DIR=".worktrees"
BRANCH_PREFIX="agent/"

if [ -t 1 ]; then
  C_PINK=$'\033[0;35m'; C_CYAN=$'\033[0;36m'; C_YELLOW=$'\033[0;33m'
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_PINK=""; C_CYAN=""; C_YELLOW=""; C_GREEN=""; C_RED=""; C_DIM=""; C_RESET=""
fi

err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
warn() { printf '%swarn:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
ok()   { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
info() { printf '%s· %s%s\n' "$C_DIM" "$1" "$C_RESET"; }

validate_task_id() {
  local id="$1"
  if [ -z "$id" ]; then
    err "task-id required"
    return 1
  fi
  if ! printf '%s' "$id" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    err "task-id must be kebab-case (lowercase, digits, hyphens), got: '$id'"
    return 1
  fi
  return 0
}

usage() {
  cat >&2 <<EOF
usage: agentic-worktree.sh <command> [args]

commands:
  start <task-id> [--from <base-ref>]   Create .worktrees/<task-id> on branch agent/<task-id>
  finish <task-id> [--keep-branch]      Remove worktree (and branch unless --keep-branch)
  list                                  List active agentic worktrees
  prune [--dry-run]                     Remove orphan worktrees (gone from disk)
  path <task-id>                        Print absolute path to .worktrees/<task-id>

Defaults:
  base-ref = HEAD (current branch)
  Branch named agent/<task-id>; worktree at .worktrees/<task-id>
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_start() {
  local task_id="${1:-}"
  shift || true
  validate_task_id "$task_id" || exit 1

  local base_ref="HEAD"
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) base_ref="${2:-}"; shift 2 ;;
      *)      err "unknown option for start: $1"; exit 1 ;;
    esac
  done

  local worktree_path="$WORKTREE_DIR/$task_id"
  local branch_name="${BRANCH_PREFIX}${task_id}"

  if [ -e "$worktree_path" ]; then
    err "worktree path already exists: $worktree_path"
    info "if stale, run: agentic-worktree.sh finish $task_id"
    exit 2
  fi

  if git show-ref --verify --quiet "refs/heads/$branch_name"; then
    err "branch already exists: $branch_name"
    info "if stale, run: git branch -D $branch_name"
    exit 2
  fi

  if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    err "base ref not found: $base_ref"
    exit 2
  fi

  mkdir -p "$WORKTREE_DIR"

  if ! git worktree add -b "$branch_name" "$worktree_path" "$base_ref" >/dev/null 2>&1; then
    err "git worktree add failed (path=$worktree_path branch=$branch_name from=$base_ref)"
    exit 3
  fi

  ok "worktree ready"
  printf '  %spath:%s   %s\n' "$C_CYAN" "$C_RESET" "$worktree_path"
  printf '  %sbranch:%s %s\n' "$C_CYAN" "$C_RESET" "$branch_name"
  printf '  %sfrom:%s   %s (%s)\n' "$C_CYAN" "$C_RESET" "$base_ref" "$(git rev-parse --short "$base_ref")"
  echo
  printf '%snext:%s cd %s && start coding agent there\n' "$C_YELLOW" "$C_RESET" "$worktree_path"
}

cmd_finish() {
  local task_id="${1:-}"
  shift || true
  validate_task_id "$task_id" || exit 1

  local keep_branch=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --keep-branch) keep_branch=true; shift ;;
      *)             err "unknown option for finish: $1"; exit 1 ;;
    esac
  done

  local worktree_path="$WORKTREE_DIR/$task_id"
  local branch_name="${BRANCH_PREFIX}${task_id}"

  if [ ! -d "$worktree_path" ]; then
    err "worktree not found: $worktree_path"
    info "try: agentic-worktree.sh list"
    exit 2
  fi

  if [ -n "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]; then
    err "worktree has uncommitted changes — commit or stash first"
    info "or force: git worktree remove --force $worktree_path"
    exit 2
  fi

  if ! git worktree remove "$worktree_path" >/dev/null 2>&1; then
    err "git worktree remove failed"
    exit 3
  fi
  ok "worktree removed: $worktree_path"

  if ! $keep_branch; then
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      if ! git branch -d "$branch_name" >/dev/null 2>&1; then
        warn "branch $branch_name not fully merged — kept (use 'git branch -D $branch_name' to force)"
      else
        ok "branch deleted: $branch_name"
      fi
    fi
  else
    info "branch kept: $branch_name"
  fi
}

cmd_list() {
  if [ ! -d "$WORKTREE_DIR" ]; then
    info "no agentic worktrees (.worktrees/ does not exist)"
    return 0
  fi

  local found=0
  git worktree list --porcelain | awk -v pfx="$REPO_ROOT/$WORKTREE_DIR/" '
    /^worktree / {
      path = substr($0, 10)
      if (index(path, pfx) == 1) {
        task = substr(path, length(pfx)+1)
        printf "%s\t", task
      } else {
        task = ""
      }
    }
    /^HEAD / && task != "" { head = substr($0, 6); printf "%s\t", substr(head, 1, 7) }
    /^branch / && task != "" { print substr($0, 8); task = "" }
  ' | column -t -s "$(printf '\t')" || true

  found=$(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  printf '\n%s%s agentic worktree(s)%s\n' "$C_DIM" "$found" "$C_RESET"
}

cmd_prune() {
  local dry_run=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true; shift ;;
      *)         err "unknown option for prune: $1"; exit 1 ;;
    esac
  done

  if $dry_run; then
    info "dry-run — listing what would be pruned:"
    git worktree prune --verbose --dry-run 2>&1 | sed 's/^/  /'
  else
    git worktree prune --verbose 2>&1 | sed 's/^/  /'
    ok "prune done"
  fi
}

cmd_path() {
  local task_id="${1:-}"
  validate_task_id "$task_id" || exit 1
  local worktree_path="$WORKTREE_DIR/$task_id"
  if [ ! -d "$worktree_path" ]; then
    err "worktree not found: $worktree_path"
    exit 2
  fi
  printf '%s\n' "$REPO_ROOT/$worktree_path"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

[ $# -lt 1 ] && usage

cmd="$1"; shift
case "$cmd" in
  start)  cmd_start "$@" ;;
  finish) cmd_finish "$@" ;;
  list)   cmd_list ;;
  prune)  cmd_prune "$@" ;;
  path)   cmd_path "$@" ;;
  -h|--help|help) usage ;;
  *) err "unknown command: $cmd"; usage ;;
esac
