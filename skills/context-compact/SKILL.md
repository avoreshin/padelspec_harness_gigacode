---
name: context-compact
description: Use when conversation context approaches 50%+ of the model window, when the agent starts repeating itself, or when verbose tool output is about to be re-injected. Walks the 5-level compaction pipeline from §2.10 of AI DISRUPT PDLC v3.5 (Budget reduction → Snip → Microcompact → Context collapse → Auto-compact) and picks the right level for the situation. Triggers on "approaching context limit", "/compact", "context bloat", "agent losing thread", "long verbose tool output".
allowed-tools:
  - Read
  - Grep
  - Glob
---

# Context Compact

You are a manual-trigger skill that picks the right compaction level for the current conversation. Based on §2.10 of AI DISRUPT PDLC v3.5 and the 5-level pipeline from GigaCode v2.1.88.

## When to run

**Manually trigger when:**
- Context window utilization is reported at ≥ 50% and the task still has multiple phases left.
- The agent starts re-fetching the same files or repeating prior conclusions.
- A subagent is about to be delegated a verbose lookup (use this skill before, not after, to avoid the bloat).
- Before any `Stop`-hook validated handoff (so the next session inherits a clean state).

**Skip when:**
- Task is single-step and will finish within 5 more tool calls.
- Output is already a summary (compacting a summary destroys signal).
- Audit trail integrity matters more than context (e.g. forensic re-run) — compaction rewrites the projection, not the audit log, but the agent's working state will diverge.

## The 5 levels (§2.10)

| Level | Mechanism | When | Side effects |
|---|---|---|---|
| 1. Budget reduction | Per-message size limit | Always on; tune the limit | Trims trailing whitespace and giant tool outputs. Cheap. |
| 2. Snip | Lightweight trim by feature flag | Long tool outputs (logs, builds) | Drops middle of long blocks, keeps head/tail. Reversible by re-running tool. |
| 3. Microcompact | Drop non-essential blocks by cache | Repeated reads of same file | Removes redundant Read results past N-th occurrence. Re-Read if needed. |
| 4. Context collapse | Read-time projection, does not mutate history | Window pressure but task still alive | Reasoner sees a projection; the underlying history stays whole. Safe. |
| 5. Auto-compact | Full LLM-generated summary | Last resort, ≥ 85% of window | Replaces history with a summary. Lossy. Use only if you can re-derive missing detail. |

## What you do

### 1. Diagnose

Ask (or check) three things:

- **Window utilization** — current tokens vs model max. If unknown, estimate from message count × avg size.
- **What hurts** — is the bloat from (a) repeated reads, (b) one giant tool output, (c) long subagent reports, or (d) accumulated reasoning?
- **What is irreplaceable** — which decisions / file contents / test runs cannot be re-derived without high cost?

### 2. Pick the level

Decision rule:

- < 50% window: do nothing. Compaction is overhead.
- 50–70%, one giant block: **L1 + L2** — tighten budget, snip the block.
- 50–70%, repeated reads: **L3** — microcompact.
- 70–85%, task has long tail: **L4** — context collapse. Preserves audit, gives the model room.
- ≥ 85% or already stuck: **L5** — auto-compact. Accept the loss.

Never jump straight to L5 without first trying L1–L4 — once you summarise, you cannot un-summarise within the same session.

### 3. Externalise what you cannot lose

Before any L3+ compaction, write what must survive into:

- The SDD (decisions, acceptance updates, blockers found).
- `NOTES.md` at repo root or task scratch dir (intermediate state, "where am I").
- Evidence bundle in-progress draft (`docs/evidence/<task>-evidence-bundle.json` partial).

Structured note-taking is the second technique in §2.10 — pair it with every compaction.

### 4. Execute

- L1/L2 are settings/flags — not actions in conversation. Report which to consider tweaking in `.gigacode/settings.json`.
- L3/L4 happen on next turn — emit a marker comment so audit shows when the projection shifted.
- L5 — call `/compact` (built-in). Confirm with user first if any field in §3 above is incomplete.

## Output

- Level chosen: `L1 | L2 | L3 | L4 | L5`.
- One sentence on why.
- A bullet list of what was externalised before compaction.
- A pointer to `NOTES.md` or evidence bundle draft path.

## Source

- AI DISRUPT PDLC v3.5 §2.10 "Context Engineering and 5-level compaction"
- §2.12 "Long-running agents and multiple context windows"
- GigaCode v2.1.88 compaction pipeline
