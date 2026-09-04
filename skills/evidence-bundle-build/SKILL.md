---
name: evidence-bundle-build
description: Use at the end of any agentic task (R1+) to assemble a schema-valid evidence bundle. Walks the fields in `.gigacode/schemas/evidence-bundle.schema.json` one by one, asks the agent to fill them from session state, and validates the result before the task can be marked done. Distinct from `/pdls:evidence` (which emits the file); this skill is the field-by-field assist. Triggers on "wrap up the task", "evidence bundle", "ready to close SDD-X", "Stop hook is asking for evidence".
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# Evidence Bundle Build

You are an assistant for assembling the evidence bundle that closes every agentic task per §2.13 of AI DISRUPT PDLC v3.5. Without it, the task is not considered done — and the `evidence-bundle-enforcer` Stop hook will block.

## When to run

**Always run at:**
- End of any R1+ task, before declaring done.
- After the `Stop`-hook fires the first warning that no evidence bundle is present.
- Before opening a PR for any task that has an SDD reference.

**Skip when:**
- R0 task with `evidence_required: false` declared in the SDD metadata.
- Continuing a session that already has an evidence bundle at `.gigacode/evidence-bundle.json` (the path the `evidence-bundle-enforcer` Stop hook reads) — use `/pdls:evidence` to update instead.

## What you do

Walk the schema fields in order. For each, pull the value from session state. If state is missing, ask once; if user defers, mark `null` and add to `unresolved_assumptions`.

### Schema fields (from `.gigacode/schemas/evidence-bundle.schema.json`)

For the canonical list, run:
```
jq -r '.required[]' .gigacode/schemas/evidence-bundle.schema.json
```

Walk-through with prompts:

1. **`task_id`** — SDD slug or task slug. From the SDD filename.
2. **`sdd_ref`** — relative path to the SDD. Verify file exists.
3. **`risk_class`** — R0..R5. Pull from SDD metadata. If diff between session and SDD, the session class wins and you must update the SDD.
4. **`acceptance_criteria`** — array; for each AC pull `status: pass | fail | skipped` and an `evidence_pointer` (test name, file path, command output line).
5. **`diff_summary`** — files changed, +/− lines. Get from `git diff --stat HEAD~N..HEAD` where N = number of atomic commits in this task.
6. **`commands_executed`** — build / test / lint / typecheck commands actually run, with exit codes. Audit trail (`.gigacode/audit/*.jsonl`) is the source of truth, not memory.
7. **`test_results`** — passed / failed / skipped counts per suite.
8. **`security_scans`** — for R3+: scan name, status, findings count. For R0–R2: `not_required` is a valid value.
9. **`unresolved_assumptions`** — anything the SDD assumed and you could not verify. Each gets a one-line description + owner + due date.
10. **`open_risks`** — anything new discovered during implementation that did not exist when SDD was approved.
11. **`subagents_used`** — list of subagent invocations with output digest (hash or first line of summary). Required if any delegation happened.
12. **`token_spend`** — best estimate. Audit trail has this if `jsonl-audit-sink` recorded it.
13. **`timestamps`** — `created`, `last_command`, `completed`. ISO 8601.

### Validation

After filling: run `jsonschema validate -s .gigacode/schemas/evidence-bundle.schema.json docs/evidence/<task>-evidence-bundle.json` (or the equivalent `ajv validate`).

If validation fails:
- Missing required field → ask user, do not invent.
- Type mismatch (e.g. string in a number field) → fix in place.
- Enum violation (e.g. `risk_class: R6`) → block, must fix in SDD first.

### Honesty rules

- **Never mark `pass` for an AC without an `evidence_pointer`.** If you ran the test and saw it pass but did not save the output, the pointer is `not_recorded` and the AC status is `skipped`, not `pass`.
- **Do not collapse `failed` tests into `skipped`** to make the bundle look clean. The Stop hook reads this.
- **`unresolved_assumptions` is normal.** A bundle with zero of them on an R3+ task is suspicious — surface this if it happens.

## Output

- Path to the written bundle: `docs/evidence/<task>-evidence-bundle.json`.
- Validation verdict: `valid | invalid: <field>`.
- One-line summary of what is still open: `unresolved=N open_risks=M`.
- Recommendation: `ready-for-PR | needs-fix: <list> | block: <reason>`.

## Source

- AI DISRUPT PDLC v3.5 §2.13 Evidence Bundle as completion protocol
- Schema: `.gigacode/schemas/evidence-bundle.schema.json` (v3.5.0)
- Companion command: `/pdls:evidence`
- Enforcer: `.gigacode/hooks/evidence-bundle-enforcer.sh`
