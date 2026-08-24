---
description: Собрать Evidence Bundle — обязательный артефакт завершения задачи
---

Собери Evidence Bundle для текущей задачи. Согласно §2.13 AI DISRUPT PDLC v3.5, задача не считается завершённой без этого артефакта.

Контекст: {{args}}

Шаги:
1. Прочитай schema: `schemas/evidence-bundle.schema.json`
2. Собери данные:
   - **diff_summary**: `git diff --stat origin/main...HEAD`
   - **files_changed**: список путей с +/- lines
   - **commands_run**: список build/test/lint команд из истории сессии
   - **tests**: запусти полный test suite, зафиксируй passed/failed/skipped + длительность
   - **lint**: запусти линтер, зафиксируй warnings/errors
   - **typecheck**: запусти typechecker, зафиксируй errors
   - **security_scan**: запусти доступный SAST (semgrep / bandit / npm audit), зафиксируй High/Critical findings
   - **unresolved_assumptions**: что осталось неподтверждённым из plan
   - **open_risks**: известные риски, не закрытые в этой задаче
   - **risk_class**: R0–R5 из SDD
   - **sdd_reference**: путь к SDD
   - **acceptance_criteria_status**: для каждого AC из SDD — passed / not covered

3. Запиши результат в `.gigacode/evidence-bundle.json` строго по schema.

4. **Stop hook** (`evidence-bundle-enforcer.sh`) проверит наличие и валидность файла перед завершением сессии. Если bundle невалидный — задача останется in_progress.

5. Покажи краткую сводку пользователю:
   ```
   ✅ Evidence Bundle generated
   - Files: <N> changed (+X / -Y)
   - Tests: <P> passed, <F> failed, <S> skipped
   - Lint: <W> warnings, <E> errors
   - Security: <C> critical, <H> high findings
   - Risk class: R<N>
   - SDD: <path>
   - AC coverage: <X>/<Y> criteria
   ```

Если тесты или security scan failed — **не помечать задачу завершённой**. Создать follow-up или вернуться к Implementation Loop.

## Next step (Phase Gate)

**Phase:** `evidence` → `done | evidence | implement` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))

После сборки bundle проверь:

1. **Schema validation:** `node ${extensionPath}/scripts/_validator.js validate ${extensionPath}/schemas/evidence-bundle.schema.json <bundle-path>` → exit 0.
2. **AC coverage:** all `acceptance_criteria_status[].status == "passed"`.
3. **Record the transition (ОБЯЗАТЕЛЬНО).** Запиши phase_transition в audit-trail — `/pdls:squash` пропустит только задачу с фазой `evidence`/`done`:

   ```bash
   bash ${extensionPath}/scripts/emit-phase-event.sh <task-id> review evidence <pass|fail> <iter> "<schema valid, AC N/N | что не так>"
   ```

   (`pass` — только при «schema valid AND AC all passed»; self-loop fix — `from=evidence`, `status=fail`, iteration+1.)

4. **Determine transition:**

| Condition | next_phase | Действие |
|---|---|---|
| schema valid AND AC all passed | `done` | §A |
| schema invalid OR JSON malformed | `evidence` (self-loop, fix) | §B |
| AC ≥ 1 failed в bundle | `implement` (откат, не done) | §C |
| Unresolved open_risks без mitigation на R3+ | `evidence` (self-loop, add mitigation) | §B |

**§A — DONE (status=pass, next_phase=done):**
```
✅ Evidence phase: bundle complete.
   Schema: valid. AC: <N>/<N> passed.
   Files changed: <X>. Tests: <T>/<T> passed.
   Risk class: R<n>. Audit_depth: <level>.

   Task COMPLETE. SDD-<slug> можно переводить в status=implemented.
```

Затем **`AskUserQuestion`**:
- `question`: "Evidence bundle complete. Что дальше?"
- `header`: "Done→?"
- `options`:
  - `label`: "Squash & prepare PR (Recommended)" · `description`: "Запустить /pdls:squash для aggregated commit + push."
  - `label`: "Keep atomic commits" · `description`: "Не squash-ить — оставить как есть, PR с полной историей."
  - `label`: "Hold for review" · `description`: "Bundle готов, но хочу посмотреть до squash."

**§B — fix bundle (status=fail, self-loop):**
```
✗ Evidence phase: bundle issues
   <конкретно что не так — schema fail / missing fields / etc>

   Recovery: fix bundle в этой же фазе (self-loop, iter counter +=1, max=3).
```

Затем **`AskUserQuestion`**:
- `question`: "Bundle issues найдены. Повторная попытка?"
- `header`: "Fix?"
- `options`:
  - `label`: "Retry /pdls:evidence (Recommended)" · `description`: "Fix issues, iter counter +=1."
  - `label`: "Back to /pdls:implement" · `description`: "Issues указывают на реальные code-проблемы, не на bundle."
  - `label`: "Escalate to human" · `description`: "Iter cap (3) близок, нужно решение."

**§C — AC failed in bundle (status=fail, rollback to implement):**
```
✗ Evidence phase: AC NOT passed
   Failed AC: <list with reasons>

   Recovery rule (loop-recovery.md): откат на /pdls:implement (не Done — задача незакончена).
   Iteration counter в Implement не сбрасывается (resume).
```

Затем **`AskUserQuestion`**:
- `question`: "AC failed в bundle. Recovery?"
- `header`: "AC fail"
- `options`:
  - `label`: "Back to /pdls:implement (Recommended)" · `description`: "Fix failed AC; iter counter в /pdls:implement продолжает."
  - `label`: "Revise SDD" · `description`: "AC сам недостижим — пересмотреть acceptance criteria."
  - `label`: "Escalate to human" · `description`: "Архитектурный gap, не решается code-фиксом."

**Fallback для всех трёх блоков** (vendor без picker'а): напечатай numbered options и жди INPUT.

**Не помечай задачу done автоматически.** SDD → `implemented` только после явного выбора "Squash" или "Keep atomic" в §A.

См. [`squash.md`](squash.md) — squash atomic commits + aggregated message + push с confirmation.

**Tip (resume):** если прервался посреди задачи — `/pdls:continue <slug>` восстановит state из audit-trail.
