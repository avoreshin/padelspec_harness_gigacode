---
name: agentic-worktree
description: Use BEFORE invoking Coding subagent on an R2+ task, or whenever multiple agentic tasks run in parallel. Creates an isolated `git worktree` at `.worktrees/<task-id>/` on branch `agent/<task-id>`, so the Coding agent never touches the main checkout. Also handles lifecycle finish/prune. Skip for R0/R1 docs-only or single-session non-prod refactors. Triggers when user says "start coding for SDD-X", "run coding agent in worktree", "parallel agentic tasks", or before any R2+/R3+/R4+ implementation phase.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# Agentic Worktree

You are a lifecycle skill for **per-task git worktrees** that isolate the Coding subagent from the main checkout. Based on `harness-docs/docs/WORKTREE-PATTERN.md` and AI DISRUPT PDLC v3.5 §2.11 (subagents as isolation) + §4.5 (risk ladder).

## When to run

**Always run before:**
- Invoking Coding subagent on R2+ task.
- Starting parallel agentic tasks (≥2 simultaneously).
- Test phase of an R3+ SDD (worktree must exist before failing tests are written).

**Skip when:**
- R0/R1 single-session docs/comments/formatting.
- One-off non-prod refactor that you'd revert via `git checkout` anyway.
- User explicitly says "no worktree, do it on main" (rare; flag this in evidence bundle).

**Run periodically:**
- Once a week — `prune --dry-run` to spot orphan worktrees.

## What you do

### 1. Verify prerequisites

Before creating a worktree:
- The task must have a `<task-id>` — kebab-case slug. Usually the slug from the SDD filename (`docs/sdd/YYYYMMDD-<slug>.md` → `<slug>`).
- The SDD must be in `status: approved`. If still `draft`, stop and ask user to approve first (per §2.5 PDLC).
- The risk class is determined and is R2+. For R0/R1, ask whether user really wants worktree overhead.
- Working tree of main checkout is clean. If dirty, ask user to commit/stash first.

Use:
```
git rev-parse --show-toplevel
git status --porcelain
grep -E '^\| \*\*Status\*\*' docs/sdd/*-<slug>.md
grep -E '^\| \*\*Risk class\*\*' docs/sdd/*-<slug>.md
```

### 2. Create the worktree

Run:
```
.gigacode/scripts/agentic-worktree.sh start <task-id>
```

Optional flags:
- `--from <ref>` — base ref (default `HEAD`). Use when the task should branch off a feature branch, not main.

The script:
- Validates `<task-id>` is kebab-case
- Refuses if `.worktrees/<task-id>` exists or branch `agent/<task-id>` exists
- Creates worktree + branch atomically
- Prints next step (`cd .worktrees/<task-id>`)

Report back the absolute path and branch name to the user so they can navigate.

### 3. Pass context to Coding subagent

When invoking the Coding subagent, include in the prompt:
- Absolute path to the worktree (`.gigacode/scripts/agentic-worktree.sh path <task-id>`)
- The branch name `agent/<task-id>`
- A reminder: "work only inside this worktree; main checkout is untouchable"
- The SDD reference (path on main checkout)

### 4. List active worktrees (situational awareness)

Before starting new work, check existing:
```
.gigacode/scripts/agentic-worktree.sh list
```

If user already has 3+ active worktrees, surface this — parallel work has cost (lockfile contention, IDE confusion, cognitive load).

### 5. Finish

When evidence bundle is accepted and SDD is `implemented`:
```
# Merge first (PR or fast-forward depending on risk class):
#   R2 — direct merge OK
#   R3 — merge via PR with security SME signoff
#   R4 — PR + human approval, separation of duties
#   R5 — PR + CAB approval + immutable branch ref in evidence

.gigacode/scripts/agentic-worktree.sh finish <task-id>
# --keep-branch if user wants to preserve agent/<task-id> for audit
```

The script refuses if worktree has uncommitted changes — no silent data loss.

### 6. Prune orphans

If you find `.worktrees/<id>/` entries that don't correspond to active git worktrees (e.g. someone `rm -rf`'d a worktree without `finish`), run:
```
.gigacode/scripts/agentic-worktree.sh prune --dry-run
.gigacode/scripts/agentic-worktree.sh prune
```

## Output format

When you complete a start/finish/list operation, report:

```
## Worktree action: <start|finish|list|prune>
- task-id: <id>
- path: <absolute path>
- branch: agent/<id>
- base-ref: <ref> (<short sha>)
- status: <ready | removed | listed>

## Next step
<concrete next action for user or Coding agent>
```

## What you do NOT do

- ❌ Do not write code in the worktree yourself. You only manage lifecycle.
- ❌ Do not modify SDD or evidence bundle (those live on main checkout).
- ❌ Do not bypass the script with raw `git worktree add` calls — the script enforces naming and conflict checks.
- ❌ Do not `rm -rf .worktrees/<id>/` to "clean up" — always go through `finish` or `prune` to keep git metadata consistent.
- ❌ Do not create worktree inside another worktree.
- ❌ Do not create a worktree if the SDD is still `draft` — that violates §2.5 (SDD-first).

## Risk-class policy (§4.5 mapping)

| Risk | Worktree | Merge strategy |
|---|---|---|
| R0 | optional (overhead > benefit) | direct |
| R1 | optional | direct |
| **R2** | **required** | PR or direct |
| **R3** | **required** | PR with security SME signoff |
| **R4** | **required** | PR + human approval, SoD |
| R5 | **required** | PR + CAB + immutable branch ref in evidence |

If user invokes Coding agent for R2+ without worktree, surface the violation and offer to create one before proceeding.

## Native GigaCode isolation (don't confuse with this skill)

GigaCode also supports `Agent({isolation: "worktree"})` natively — that creates an ephemeral worktree for the duration of a single subagent invocation, then removes it. Use that for short single-session subagent tasks (Explore, parallel queries).

This skill is for **multi-session, multi-commit feature work** where the worktree must persist between sessions. Different use case, complementary mechanisms.

When in doubt:
- Will the task complete in one subagent call? → native `isolation: "worktree"`
- Will the task span multiple commits / sessions / days? → this skill

## References

- `harness-docs/docs/WORKTREE-PATTERN.md` — full pattern documentation
- `.gigacode/scripts/agentic-worktree.sh` — implementation
- `.gigacode/agents/coding.md` — Coding subagent mandate (R2+ filesystem boundary)
- AI DISRUPT PDLC v3.5 §2.11 (subagents as isolation), §4.5 (risk ladder)
