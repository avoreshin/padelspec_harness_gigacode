---
name: risk-classify-deep
description: Use when `/pdls:risk-classify` returns an answer the user wants to challenge, when the task crosses domain boundaries (e.g. touches both UI and infra), or when the SDD scope is broad enough that a single class hides relevant risk. Runs a 4-axis interview — data sensitivity × stage radius × blast radius × reversibility — and produces a justified R0–R5 verdict per §4.5 PDLC. Triggers on "is this really R2 or R3?", "deep risk review", "/pdls:risk-classify --deep", "feature spans multiple domains".
allowed-tools:
  - Read
  - Grep
  - Glob
---

# Risk Classify Deep

You are an interview-style extension of `/pdls:risk-classify` that interrogates the task along four orthogonal axes before assigning a class. Based on §4.5 of AI DISRUPT PDLC v3.5 and `.gigacode/policies/risk-ladder.yaml`.

## When to run

**Always run when:**
- `/pdls:risk-classify` returned a class and the user pushed back.
- The SDD touches more than one domain (UI + infra, data + permissions, etc.).
- An R2 candidate references auth, payments, PII, or production data anywhere in its scope — even tangentially.
- A reviewer says "are you sure this is R1?".

**Skip when:**
- Task is unambiguously R0 (docs, comments, formatting in non-prod paths).
- A previous deep classification exists for an identical scope within the last 30 days.

## The four axes

For each axis pick a level 1–5. The final class is **the maximum of the four**, then bumped up one if any axis is at 5 and the others are not all ≤ 2 (no inconsistent profiles).

### Axis 1 — Data sensitivity

| Level | What is touched |
|---|---|
| 1 | Public docs only; no user-controlled input read |
| 2 | Internal repo state (code, configs); no PII / secret |
| 3 | Test fixtures that mimic PII; no real user data |
| 4 | Real user data, payments, auth tokens, secrets |
| 5 | Regulated data (PHI, KYC, financial transaction logs) |

### Axis 2 — Stage radius

| Level | Where the change lands |
|---|---|
| 1 | Local working tree only; nothing committed |
| 2 | Feature branch + non-prod environment |
| 3 | Main branch behind feature flag (off by default in prod) |
| 4 | Production with rollout; can be reverted within an hour |
| 5 | Production at full traffic; revert window > 1 hour |

### Axis 3 — Blast radius

| Level | Who is affected if it goes wrong |
|---|---|
| 1 | Only this agent's local session |
| 2 | Only this team's tools |
| 3 | Multiple teams' workflows |
| 4 | All internal users of the product |
| 5 | External users; revenue or compliance exposure |

### Axis 4 — Reversibility

| Level | How hard to undo |
|---|---|
| 1 | `git revert`; no state changes outside repo |
| 2 | Code revert + redeploy; no data migration |
| 3 | Requires data migration, but data is recoverable |
| 4 | Requires data migration; some data loss possible |
| 5 | Irreversible (deleted prod data, sent emails, money moved, model retrained) |

## Mapping to R0–R5

Compute `max_axis` and `is_inconsistent` (true if any axis is at 5 while another is ≤ 2).

| max_axis | Result if consistent | Result if inconsistent |
|---|---|---|
| 1 | R0 | R1 (something is wrong, bump for safety) |
| 2 | R1 | R2 |
| 3 | R2 | R3 |
| 4 | R3 | R4 |
| 5 | R4 | R5 |

> **Inconsistency rule.** If one axis is at 5 and another is at 1 or 2, you almost certainly missed something. Bump and force a re-review.

> **The GIGACODE.md tiebreaker.** "При сомнении — выбирать класс выше, не ниже." If the interview leaves you on the boundary, take the higher class.

## Interview script

Ask one axis at a time, in this order: **data → reversibility → blast → stage**. Reversibility comes second because it usually settles the class on its own. Stage comes last because it is the easiest to mis-estimate without the other three set first.

For each axis, ask:
1. "On axis X, what level fits this task: 1, 2, 3, 4, or 5?"
2. "Quote the specific scope element that puts it at that level."
3. "Is there anything in the SDD non-goals that explicitly excludes a higher level?"

Record answers and quotes in the SDD §5.5 "Deep risk classification" section.

## Output

- Per-axis levels with one-line justification each.
- Final class: `R0 | R1 | R2 | R3 | R4 | R5`.
- Inconsistency flag: `consistent | bumped`.
- Comparison with `/pdls:risk-classify` shallow verdict: `match | upgraded | downgraded`.
- If upgraded: list of approvals now required (per §4.5 ladder).
- If downgraded: explicit rationale — downgrading without explanation is a red flag.

## Source

- AI DISRUPT PDLC v3.5 §4.5 risk-adaptive permission ladder
- Policy: `.gigacode/policies/risk-ladder.yaml`
- Shallow command: `/pdls:risk-classify`
- GIGACODE.md §3 tiebreaker
