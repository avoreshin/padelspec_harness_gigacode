---
name: harness-principles
description: Use BEFORE writing or approving an SDD for an R3+ task, or when reviewing harness changes that touch hooks/policies/permission gates. Walks through the 13 design principles from §2.2 of AI DISRUPT PDLC v3.5 (Harness over Model) as a checklist and asks you to record how each principle is reflected — or explicitly waived with reason. Skip for R0/R1 docs/refactor. Triggers on "start SDD for R3", "approving auth/payment/PII work", "reviewing hook change", "policy-as-code edit".
allowed-tools:
  - Read
  - Grep
  - Glob
---

# Harness Principles Checklist

You are a pre-design checklist skill that enforces the 13 Harness-over-Model principles from AI DISRUPT PDLC v3.5 §2.2 before an R3+ task gets implementation green-light.

## When to run

**Always run before:**
- Approving an SDD with risk class R3 or higher.
- Merging a change under `.gigacode/hooks/`, `.gigacode/policies/`, or `.gigacode/settings.json` that touches a permission gate.
- Adding or modifying an MCP server that exposes write or destructive operations.

**Run on demand:**
- Reviewing a harness PR from another team and asking "did they think through this?"
- Quarterly harness self-review (audit_policy.quarterly_review).

**Skip when:**
- R0/R1 docs / formatting / local refactor.
- Editing skill SKILL.md guidance text only (no hook or policy change).

## What you do

Walk the 13 principles in order. For each: record one of three answers in the SDD §11 "Principles compliance" table (create the section if missing).

| Code | Answer | Meaning |
|---|---|---|
| ✓ | Reflected | The SDD or implementation explicitly addresses this principle. Quote the section. |
| n/a | Not applicable | Principle does not apply to this scope. State why in one sentence. |
| ⚠ waived | Waived | Principle is relevant but consciously not addressed. Requires sign-off from Security or Platform owner. |

### The 13 principles (§2.2)

1. **Deny-first with human escalation.** Unknown actions escalate, not allow. Check: do new hooks default to `deny`? Is there an `ask` path for ambiguity?
2. **Graduated trust spectrum.** Five to seven autonomy levels, not binary on/off. Check: is autonomy explicitly bound by risk class, not a global toggle?
3. **Defense in depth.** Multiple independent layers; one failing must still block. Check: are there ≥ 2 independent gates for the destructive case (e.g. hook + CI workflow + branch protection)?
4. **Externalized programmable policy.** Policy lives in config and hooks, not hard-coded in agent prompts. Check: nothing being added to GIGACODE.md that should be in `risk-ladder.yaml` or a hook.
5. **Context as scarce resource.** Multi-level compaction pipeline. Check: does the change increase steady-state context size? If yes, justify or pair with `/skill context-compact`.
6. **Append-only durable state.** JSONL audit trail for compliance. Check: any new state-changing action emits an audit event matching `audit-event.schema.json`.
7. **Minimal scaffolding, maximal operational harness.** Harness creates conditions, does not constrain. Check: are we adding a guardrail or removing a degree of freedom that did not need removing?
8. **Values over rules.** Guidance (context) + deterministic enforcement (policy). Check: vague values are in GIGACODE.md or skill; hard rules are in hook or policy. No reversed pairs.
9. **Composable multi-mechanism extensibility.** Tools / Skills / Hooks / Plugins / MCP — choose by context cost (§4.9). Check: are we using the right mechanism, or the convenient one?
10. **Reversibility-weighted risk.** Read-only is light oversight; destructive is heavy. Check: irreversible operations have human approval gates; reversible ones do not (avoid friction overshoot).
11. **Transparent file-based configuration.** Markdown files under git, no opaque DB. Check: nothing being introduced that requires out-of-repo state to reproduce the harness behavior.
12. **Isolated subagent boundaries.** Subagent ≠ parent context + permissions. Check: any new subagent has its own scope, not a copy of parent. Tool list is the minimum it needs.
13. **Graceful recovery and resilience.** Retry, fallback, reactive compaction. Check: failure paths handle re-entry; idempotency where it matters.

### Output format

Append (or update) §11 in the SDD:

```markdown
## 11. Principles compliance (§2.2)

| # | Principle | Status | Note |
|---|---|---|---|
| 1 | Deny-first with human escalation | ✓ | §4 AC-2 — new hook returns exit 2 on unknown tool |
| 2 | Graduated trust spectrum | n/a | scope is single-task, no autonomy dial introduced |
| 3 | Defense in depth | ⚠ waived | only pre-commit gate, no CI gate yet — accepted because pre-commit is mandatory in install; tracked as BL-XXX |
| ... | ... | ... | ... |
```

Any `⚠ waived` row blocks SDD approve until signed off by the right role (Security for R3+, Platform owner for harness-internal changes).

## Output (what you return)

- The filled §11 table inserted into the SDD.
- A one-line verdict: `principles-compliance: pass | waived (N) | block`.
- If `block`: list of which principles need a fix before approve.

## Source

- AI DISRUPT PDLC v3.5 §2.2 "Harness over Model"
- ADR `docs/adr/0001-harness-over-model.md`
- §4.5 risk ladder
- §4.9 extension ladder (Hooks / Skills / Plugins / MCP)
