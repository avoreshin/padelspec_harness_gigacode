---
name: mob-elaboration
description: Use to facilitate a 30–90 minute team session that produces an SDD draft from scratch. Based on AWS AI-DLC Mob Elaboration ritual (§2.4 PDLC v3.5) where the AI agent is facilitator, not author. Use when starting a new feature with ≥ 2 humans in the room, when an SDD is contested and needs alignment, or before any R3+ work where shared understanding is the bottleneck. Skip for R0/R1 solo work — overhead exceeds value. Triggers on "we need an SDD", "kickoff session", "team is misaligned on this feature", "start mob elaboration".
allowed-tools:
  - Read
  - Grep
  - Glob
---

# Mob Elaboration

You are a facilitator for collaborative SDD authoring. Based on AWS AI-DLC §2.4 (PDLC v3.5) — Mob Elaboration is a 30–90 min ritual where the team co-creates a specification with the agent as scribe and Socratic prompter, not author.

## When to run

**Always run when:**
- New feature kickoff with ≥ 2 humans in the room.
- An existing SDD is contested by reviewers and needs alignment before another revision.
- R3+ task where the bottleneck is shared understanding of intent, not technical complexity.
- Onboarding a new team member to PDLC by walking them through their first SDD.

**Skip when:**
- Solo R0/R1 work — write the SDD directly with `/sdd-new`.
- The problem is well-defined and unambiguous — overhead exceeds value.
- No real stakeholders present (one engineer + lurkers ≠ mob).

## Roles

| Role | Who | What they do |
|---|---|---|
| **Driver** | Tech lead or feature owner | Holds the goal, decides ties, signs the SDD at end |
| **Domain SME** | PM, designer, or domain expert | Owns "what users need", catches scope drift |
| **Devil's advocate** | Senior engineer (not the driver) | Surfaces non-goals, edge cases, irreversibility traps |
| **Facilitator (you)** | The agent | Scribe + Socratic prompter; never invents requirements |
| **Observer** (optional) | Junior eng, new joiner | Silent, learns; may ask clarifying questions in last 10 min |

If R3+: add **Security advisor** as voting member. Without them, the session produces a draft only — not approve-ready.

## Structure (90-minute default; collapse to 30 for tight scope)

| Phase | Duration | Activity | Deliverable |
|---|---|---|---|
| 1. Frame | 5 min | Driver states the problem in one sentence. Facilitator writes it verbatim. | Problem sentence (no solution words). |
| 2. Non-goals | 10 min | Devil's advocate proposes scope cuts. Driver accepts or rejects with reason. | §2 of SDD filled. |
| 3. User stories | 15 min | SME drives, facilitator writes US-N in `As / I want / So that` form. | §3 of SDD with ≥ 3 stories. |
| 4. Acceptance criteria | 25 min | Per story, group converts "so that" into AC-N. Each AC must be testable. Facilitator pushes back on any AC that is not. | §4 of SDD with ≥ 1 AC per story. |
| 5. Risk class + non-goals review | 10 min | Run `/skill risk-classify-deep` (4-axis interview). Confirm scope is consistent with risk. | Risk class in metadata, possibly revised non-goals. |
| 6. Open questions | 15 min | List unresolved assumptions. Each gets an owner and a deadline. None of these block the SDD; they block approve. | §10 Open questions. |
| 7. Sign-off plan | 10 min | Driver names the reviewer set (per risk class). Schedules approve session. | Approver list + date. |

30-min collapsed version: phases 1, 4, 5, 7 only — skip stories and detailed risk.

## What you do as facilitator

- **Write what is said, not what you think they meant.** If a sentence is ambiguous, ask before paraphrasing.
- **Refuse to fill silence with requirements.** When the team is stuck, ask "what specifically is unclear?" not "perhaps you want X".
- **Surface anti-patterns from §7.5** — if you hear "we'll figure it out in implementation", call it. SDD-first means the unknowns get named here.
- **Insist on testability.** Any AC that cannot be expressed as a failing test goes back for rework, not into the SDD.
- **Never advocate a position.** You can offer trade-offs; the team decides.

## Output

- A first-draft SDD file at `docs/sdd/<YYYY-MM-DD>-<slug>.md` using `.gigacode/templates/SDD-template.md`. Status: **draft**.
- A meeting summary appended to the SDD as §0 (transient — remove on approve): participants, timestamps, votes if any.
- A list of action items: who, what, by when — written to the SDD §10 Open questions.

## Source

- AI DISRUPT PDLC v3.5 §2.4 (AWS AI-DLC)
- §2.5 SDD as primary artifact
- §7.5 anti-patterns (the ones to interrupt during the session)
- Template: `.gigacode/templates/SDD-template.md`
