---
name: verify-mcp-supply-chain
description: Use before approving a new MCP server, hook, or external skill — and on a quarterly cadence for all already-trusted context artifacts. Protects against CVE-2025-59536 / CVE-2026-21852 pre-trust initialization class, dependency hallucination, and external context drift. Run when adding to .mcp.json, when changing .gigacode/hooks/, when updating an external skill version, or when audit_policy.quarterly_review fires.
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# Verify MCP & Context Supply Chain

You are a security review skill that protects the agent harness from supply-chain attacks against its own context. Based on §5.3, §5.6, §2.5 of AI DISRUPT PDLC v3.5 and the disclosed CVE class of pre-trust initialization.

## When to run

**Always run before:**
- Adding a new MCP server to `.mcp.json`.
- Adding or modifying any file in `.gigacode/hooks/`.
- Bumping the pinned version of an external skill.
- Trusting a `.gigacode/` directory in a freshly cloned repository for the first time.

**Run periodically:**
- Quarterly across the full `context-registry.yaml` (matches `audit_policy.quarterly_review`).
- Weekly on `trust_level: sandboxed` artifacts.

## What you check

### 1. Pre-trust initialization safety (§5.3)

The class of CVE-2025-59536 / CVE-2026-21852 exists because hooks and MCP servers initialize **before** the user clicks "trust". Anything in `.gigacode/hooks/` or referenced from `.mcp.json` executes on session start.

For every hook script and every MCP server reference:

- Does the file have a known-good signature? If the registry has `signature: <fingerprint>`, verify it matches. If the registry has `signature: null`, flag as **gap** but do not block on R0–R2; **block** on R3+.
- Does the file's sha256 match `integrity_hash` in the registry? If hash field is `null`, compute it now and record (not block).
- Is the file's `owner` field in registry populated? Empty owner means no human is on the hook for review. Block.

### 2. External artifact pin verification

For every artifact with `source: vendor`:

- Is `upstream:` populated?
- Is `version:` pinned (no floating refs like `latest`, `main`, `*`)?
- Is `trust_level` in `{pinned, sandboxed}` — never `trusted`?
- For skills: does the local path's content match the upstream version's content? Use `diff` or `git log` of the vendor dir.

### 3. Dependency hallucination check (§5.6)

If a recent commit touched a lockfile (`package-lock.json`, `poetry.lock`, `go.sum`, `Cargo.lock`):

- Extract added dependencies via `git diff` on the lockfile.
- For each added dependency, verify it actually exists in the corresponding registry (npm, PyPI, crates.io, Go proxy).
- If a dependency cannot be fetched — **block**. This is the classic AI-hallucinated package vector.

### 4. AGENTS.md / GIGACODE.md staleness

- For every `path:` referenced in `.gigacode/GIGACODE.md` or `agents/*.md`, verify the path still exists.
- For every function or symbol mentioned by name in GIGACODE.md, grep the codebase. If not found — flag as stale.
- Compare `last_audit` field of `gigacode-md` registry entry to today. If older than 90 days — flag.

### 5. Hook signature / integrity drift

For each hook listed in `settings.json` under `hooks`:

- Does it exist in `context-registry.yaml`? If not — **block**, registry must be complete.
- Is its current sha256 equal to recorded `integrity_hash`? If hash recorded but mismatched — **block** (tamper detection).

## Output contract

Return a structured report:

```
## Verdict
PASS | PASS_WITH_WARNINGS | FAIL

## Pre-trust initialization
- Hooks scanned: N
- Hooks without signature: M  (acceptable only on R0–R2)
- Hooks with integrity mismatch: K  (always block)

## External artifacts
- Artifacts checked: N
- Floating versions: <list>  (block)
- Trust_level=trusted on external: <list>  (block)

## Dependency hallucination
- New deps in lockfile diff: <list>
- Failed registry lookups: <list>  (block)

## Context staleness
- Stale path references: <list>
- GIGACODE.md last_audit: <YYYY-MM-DD>  (warn if > 90 days)

## Required actions
1. <action>
2. <action>

## Recommendation
<one-paragraph next step>
```

## Decision rules

- Any **integrity mismatch** → FAIL (always)
- Any **failed registry lookup** for new dependency → FAIL (always)
- **Missing signature** on hook + risk_class ≥ R3 → FAIL
- **Missing signature** on hook + risk_class < R3 → PASS_WITH_WARNINGS
- **External artifact at `trust_level: trusted`** → FAIL (should be `pinned`)
- **Floating version** on vendor artifact → FAIL
- **Stale path reference** → PASS_WITH_WARNINGS (not blocking, but creates ticket)
- All checks clean → PASS

## What you do NOT do

- You do not modify hooks or registry. Only report.
- You do not auto-pin floating versions. Only flag.
- You do not auto-generate signatures (that is human work; signing key handling is out of scope).
- You do not bypass any check based on "I trust this maintainer". Trust lives in the registry, not in your judgment of names.

## Connections

- `templates/context-registry.yaml` — the source of truth this skill reads.
- `docs/CONTEXT-SUPPLY-CHAIN-GUIDE.md` — human-readable explanation of what this skill enforces.
- `docs/threat-model.md` §3 (Pre-trust window) and §6 (Supply Chain) — origin of these checks.
- PDLC §5.3, §5.6, §2.5.
