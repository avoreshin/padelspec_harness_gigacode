---
description: Implement — реализовать минимальный код, чтобы failing tests прошли (Phase Gate: implement phase)
---

Запусти Implement-фазу для задачи: {{args}}

**Phase:** `implement` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))
**Mandate:** минимальный production-код, чтобы тесты от `test` фазы стали зелёными. **Не модифицировать тесты.**
**Iteration cap:** 3. На 4-й попытке — mandatory escalation.

## Процесс

1. **Identify SDD + check prior phase.** Если `{{args}}` пустой — попроси slug. Найди SDD в `docs/sdd/`. Проверь:
   - status = `approved` или `implemented` (для retry)
   - тесты из фазы `test` existуют и **падают** (= 1+ failing)
   - Если тестов нет — STOP, предложи `/pdls:test <slug>` сначала.

2. **Check iteration counter.** Выполни `bash ${extensionPath}/scripts/workflow-state.sh <task-id>` (парсит `phase_transition` события из audit-trail). Iteration:
   - Если `status=not_found`/`no_audit` → iteration=1
   - Если `current_phase=implement` и `last_status ∈ {iterate, fail}` → iteration = `iteration` из вывода + 1. `fail` здесь — та же неудавшаяся попытка (агент тронул тест-файлы, §7), и считать её нулевой значит обходить кэп чередованием статусов
   - Если `current_phase=review` и `last_status=fail` (возврат по REJECT major) → iteration = `iteration` из вывода, **счётчик продолжается**: фаза `review` пишет текущую итерацию задачи, не единицу
   - Иначе (`current_phase` — другая фаза) → iteration=1
   - Если iteration ≥ 4 — **STOP, mandatory escalation**, см. §10 ниже. Это же запишет и гейт `implement-iteration-cap-gate`: при `iteration ≥ 4` он пропускает только `status=escalate`.

3. **For R2+: enforce worktree boundary.** Прочитай SDD risk_class:
   - R0/R1: можно работать на main checkout
   - R2+: проверь, что находишься в `.worktrees/<task-id>/`. Если нет — запусти `bash ${extensionPath}/scripts/agentic-worktree.sh start <task-id>` и переключись туда.

4. **Delegate to `coding` subagent.** Используй Agent tool с `subagent_type: "coding"`. Передай:
   - SDD
   - Implementation plan
   - **Списки failing tests** из фазы test
   - **Current iteration count**
   - **Constraint:** запрет на Edit/Write в test-файлы (test-files-protector.sh в pdlc-harness блокирует hard, в `-work` — soft warning)

5. **Validate structured output:** найди `<!-- phase-transition:json -->` блок. Validate через `bash ${extensionPath}/scripts/check-phase-transition.sh`. Прочитай:
   - status: pass / iterate / escalate
   - next_phase
   - iteration (должен совпадать с подсчитанным в шаге 2)

6. **Record the transition (ОБЯЗАТЕЛЬНО).** Запиши phase_transition в audit-trail — без этого `/pdls:continue`, `/pdls:squash` и iteration cap не увидят фазу:

   ```bash
   bash ${extensionPath}/scripts/emit-phase-event.sh <task-id> <from> implement <status> <iteration> "<коротко: причина/результат>"
   ```

   где `<from>` = `test` для первой итерации, `implement` для retry (self-loop), `review` при resume после REJECT major; `<status>` = `pass` / `iterate` / `escalate` / `fail` из шага 5.

7. **Determine next step:**

   | status | iteration | next_phase | Действие |
   |---|---|---|---|
   | `pass` | any | `review` | Next step §8 |
   | `iterate` | 1 or 2 | `implement` | Retry prompt §9 |
   | `iterate` | 3 | `implement` | ⚠ Warning: следующий fail = mandatory escalation §9 |
   | `escalate` | 3+ | `plan` | Mandatory escalation §10 |
   | `fail` | any | `implement` | Если agent тронул test files → revert + retry §9 |

8. **Next step (status=pass):**

   ```
   ✅ Implement phase passed.
      All tests pass (<N> passed, 0 failed).
      Lint: <result>. Typecheck: <result>.
      Iteration: <n>/3.
      Files changed: <list>
   ```

   Затем **вызови `AskUserQuestion`**:
   - `question`: "Implement готов, все тесты pass. Что дальше?"
   - `header`: "Impl→?"
   - `options`:
     - `label`: "Continue → /pdls:review (Recommended)" · `description`: "Передать на code review против SDD."
     - `label`: "Iterate (более clean реализация)" · `description`: "Hardening / refactor; тесты остаются pass."
     - `label`: "Stop & save" · `description`: "Сохранить state, выйти. /pdls:continue вернёт."

   **Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

   В auto-mode (R0/R1) переход к `/pdls:review` автоматический.

9. **Retry (status=iterate):**

   ```
   ⟳ Implement phase: iterate (<failed>/<total> tests still failing)
      Iteration: <n>/3
      Reason: <reason из structured output>
   ```

   Если iteration < 3 — **`AskUserQuestion`**:
   - `question`: "Tests still failing (iteration <n>/3). Продолжаем?"
   - `header`: "Iterate"
   - `options`:
     - `label`: "Continue → /pdls:implement (Recommended)" · `description`: "Ещё одна итерация (n+1)."
     - `label`: "Revise SDD" · `description`: "Откат на /pdls:sdd-new — вероятен AC gap."
     - `label`: "Stop" · `description`: "Прервать loop, разобраться вручную."

   Если iteration = 3:
   ```
   ⚠ ПОСЛЕДНЯЯ итерация (3/3). Следующий fail = mandatory escalation на /pdls:sdd-new.
      Recommended: подготовить SDD revision СЕЙЧАС, если есть подозрение на AC gap.
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "Последняя итерация (3/3). Пробуем или откатываемся?"
   - `header`: "Last try"
   - `options`:
     - `label`: "Try iteration 3 (Recommended)" · `description`: "Последняя попытка; следующий fail = mandatory escalation."
     - `label`: "Revise SDD now" · `description`: "Откат на /pdls:sdd-new сейчас — если AC gap уже очевиден."

10. **Mandatory escalation (status=escalate, iteration ≥ 3):**

   Прочитай [`docs/playbooks/loop-recovery.md`](../../docs/playbooks/loop-recovery.md) строка «Implement / tests still failing, iter = 3».

   ```
   ✗ Implement phase: ESCALATE (iteration <n>, hit cap)
      Reason: <reason>
      Hypothesis: SDD неполный или AC недостижимы в текущей архитектуре.

   Recovery rule (§7 phase-gate-protocol): mandatory rollback на /pdls:sdd-new для SDD revision.
   ⚠ Human required (§9 GIGACODE.md): прежде чем revis-ить SDD, опиши явно:
      - какие AC не сходятся
      - что именно ломается в текущей архитектуре
      - предложение по изменению (relax AC / добавить контракт / split task)
   ```

   Затем **`AskUserQuestion`** (всегда manual — human required, §9):
   - `question`: "Iteration cap hit. Подтверждаешь rollback на /pdls:sdd-new?"
   - `header`: "Escalate"
   - `options`:
     - `label`: "Rollback → /pdls:sdd-new (Recommended)" · `description`: "Revise SDD с описанием AC gap (обязательно human review)."
     - `label`: "Hold — решаю вручную" · `description`: "Оставить как есть, разобраться без rollback."

   **Не делай rollback автоматически.** Жди явного решения.

## Правила (cross-ref агент'а `${extensionPath}/agents/coding.md`)

- Atomic commits (один логический шаг = один commit)
- **Запрещено** «подкрутить» тест — если test agent написал неправильный test, откатываемся на `/pdls:test` фазу
- R2+ — только в `.worktrees/`
- При обнаружении out-of-scope изменений — STOP + audit `escalation` event
- Не использовать `--no-verify` при коммите

## Привязка к Phase Gate Protocol

- State machine: `implement` принимает transition из `test` или self-loop (iter+=1) или из `review` (REJECT major resume)
- Iteration cap §5 phase-gate-protocol: max=3
- Audit `phase_transition` event при каждом transition + `escalation` event при iter ≥ 3 fail

**Tip (resume):** если прервался посреди iter — `/pdls:continue <slug>` восстановит state (включая iteration counter) из audit-trail.
