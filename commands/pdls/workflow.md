---
description: Workflow orchestrator — ведёт через все фазы loop'а (auto-mode для R0/R1, manual для R2+)
---

Запусти полный workflow для задачи: {{args}}

**Source SDD:** docs/sdd/20260523-workflow-orchestration.md (R1, implemented)
**Mode decision:** автоматически по `risk_class` из SDD.

## Процесс

1. **Получи slug** из `{{args}}`. Если пустой — попроси у пользователя или предложи `/pdls:sdd-new <slug>` сначала.

2. **Найди SDD** в `docs/sdd/` по slug. Проверь:
   - SDD existувует
   - status = `approved`
   - risk_class определён (R0..R5)
   - acceptance_criteria ≥ 1

   Если что-то не так → STOP, предложи `/pdls:sdd-new <slug>` для revision.

3. **Определи mode по risk_class:**

   | risk_class | mode | Поведение |
   |---|---|---|
   | R0 | **auto** | Все фазы подряд, confirm только при status≠pass |
   | R1 | **auto** | Same |
   | R2 | **manual** | Confirm на каждом transition (current Next-step prompts) |
   | R3+ | **manual** | Confirm + warning «high-risk», предложить independent reviewer перед /pdls:test |

4. **Печать execution plan** перед стартом:
   ```
   Workflow orchestration for <task-id>
     Risk class:  R<n>
     Mode:        <auto | manual>
     Phases:      plan → test → implement → review → evidence
     Iteration cap (Implement): 3
     Recovery: loop-recovery.md table
   ```

   Затем **вызови инструмент `AskUserQuestion`**:
   - `question`: "Execution plan готов. Запускаем workflow?"
   - `header`: "Start?"
   - `options`:
     - `label`: "Start → /pdls:plan (Recommended)" · `description`: "Погнали по фазам plan → test → implement → review → evidence."
     - `label`: "Revise SDD first" · `description`: "Нужны правки в SDD перед стартом — возврат к /pdls:sdd-new."
     - `label`: "Cancel" · `description`: "Не запускать orchestration сейчас."

   **Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

5. **Последовательно запускай фазы:**

   - **/pdls:plan <slug>** → wait for phase-transition output
   - **status=pass** + auto-mode → auto-continue на /pdls:test
   - **status=pass** + manual-mode → ask «Готов к /pdls:test?»
   - **status≠pass** (любой mode) → останов, recovery prompt из loop-recovery.md

   Логика для каждой фазы — повторение того же decision pattern.

6. **На фазе Implement (iteration loop):**

   - iter=1 → run coding agent → wait phase-transition
   - status=pass → next phase (review)
   - status=iterate + iter<3 → auto-continue (auto-mode) или confirm (manual)
   - status=iterate + iter=3 → ⚠ WARNING, всегда ask user (auto-mode НЕ bypass'ит iter cap)
   - status=escalate → STOP, mandatory rollback на /pdls:sdd-new

7. **На фазе Review:**

   - verdict APPROVE → next phase (evidence)
   - REJECT major → recovery /pdls:implement (auto-mode: ask «продолжаем implement?»; manual: standard)
   - REJECT critical → STOP, architectural rollback /pdls:sdd-new (всегда manual confirm, **human required**)

8. **На фазе Evidence:**

   - bundle valid + AC all passed → DONE
   - bundle invalid → self-loop fix (max 3 iterations)
   - AC failed → rollback /pdls:implement

9. **При DONE:**
   ```
   ✓ Workflow для <task-id> завершён успешно.
      Phases passed: 5/5
      Total iterations (Implement): <n>
      Audit events: <count>
   ```

   Затем **вызови инструмент `AskUserQuestion`**:
   - `question`: "Workflow завершён. Что дальше?"
   - `header`: "Done→?"
   - `options`:
     - `label`: "Continue → /pdls:squash (Recommended)" · `description`: "Aggregated commit + подготовка PR."
     - `label`: "Stop here" · `description`: "Оставить atomic commits как есть; PR соберу вручную."

   **Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

## Auto-mode правила (INV-2, INV-3)

- **Auto-mode разрешён только** для risk_class ∈ {R0, R1}.
- **На любом status≠pass** auto-mode переходит в manual (всегда ask user).
- **Iteration cap (iter=3 Implement)** — всегда ask, даже в auto-mode.
- **Critical review reject** — всегда ask, даже в auto-mode.

## Manual-mode правила

- Identical к current Next-step prompts в каждом command file.
- Каждый transition требует явного `yes` от user.
- Recovery actions — из loop-recovery.md, как обычно.

## Negative cases

- ❌ Если SDD не approved → STOP, не запускай /pdls:plan.
- ❌ Если risk_class=R2+ и user явно потребовал auto → отказ, объяснение из INV-2.
- ❌ Если на любой фазе hook block — STOP, не bypass-ить.
- ❌ Если token budget overflow (cost-circuit-breaker) — STOP.

## Связи

- [`./pdls:continue.md`](continue.md) — resume если прервался
- [`./pdls:squash.md`](squash.md) — финал перед PR
- [`./pdls:sdd-new.md`](sdd-new.md), [`./pdls:plan.md`](plan.md), [`./pdls:test.md`](test.md), [`./pdls:implement.md`](implement.md), [`./pdls:review.md`](review.md), [`./pdls:evidence.md`](evidence.md) — фазы loop
- [`../../docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md)
- [`../../docs/playbooks/loop-recovery.md`](../../docs/playbooks/loop-recovery.md)
