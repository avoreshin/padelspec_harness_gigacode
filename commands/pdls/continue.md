---
description: Resume workflow — продолжить задачу с того места, где остановился (читает audit-trail)
---

Продолжи workflow для задачи: {{args}}

**Source SDD:** docs/sdd/20260523-workflow-orchestration.md (R1, implemented)

## Процесс

1. **Получи task_id** из `{{args}}`. Если пустой — попроси у пользователя slug или SDD ID.

2. **Прочитай workflow state** через helper:
   ```bash
   bash ${extensionPath}/scripts/workflow-state.sh <task-id> --text
   ```

   Скрипт выведет:
   - `current_phase` (последняя зафиксированная фаза)
   - `last_status` (pass / fail / iterate / escalate)
   - `iteration` (если Implement)
   - `next_recommended_command`

3. **Обработай результат:**

   **a) Task не найден в audit** (exit 1):
   ```
   ⚠ Задача <task-id> не зафиксирована в audit-trail.
      Возможные причины:
      - SDD ещё не создан → запусти /pdls:sdd-new <slug>
      - Phase Gate hooks не активированы (Phase Gate Protocol soft enforcement)
      - audit-trail в другой локации (.gigacode/audit/)
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "Задача <task-id> не в audit-trail. Что делаем?"
   - `header`: "No task"
   - `options`:
     - `label`: "Create SDD → /pdls:sdd-new (Recommended)" · `description`: "Задача ещё не заведена — начинаем со спеки."
     - `label`: "Cancel" · `description`: "Проверю task-id / локацию audit вручную."

   **b) Task найден, status=pass** (нормальное продолжение):
   ```
   ✓ Workflow state: phase=<X>, iteration=<n>, status=pass
      Last updated: <ISO timestamp>
      Recommended next: <next_command> <task-id>
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "Resume: recommended next — <next_command>. Что дальше?"
   - `header`: "Resume"
   - `options`:
     - `label`: "Run <next_command> (Recommended)" · `description`: "Продолжаем с зафиксированной фазы."
     - `label`: "Другой шаг" · `description`: "Выбрать иную команду вручную."
     - `label`: "Отложить" · `description`: "Ничего не запускать сейчас."

   **c) Task найден, status=iterate** (продолжаем итерацию):
   ```
   ⟳ Workflow state: phase=implement, iteration=<n>/3, status=iterate
      Last failure: <last reason из audit>

   Recommended: /pdls:implement <task-id> (iteration <n+1>)
   ⚠ Iteration cap = 3. Если на следующей попытке fail — mandatory escalation.
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "status=iterate (iteration <n>/3). Продолжаем?"
   - `header`: "Iterate"
   - `options`:
     - `label`: "Continue → /pdls:implement (Recommended)" · `description`: "Ещё одна итерация (n+1)."
     - `label`: "Revise SDD" · `description`: "Откат на /pdls:sdd-new — вероятен gap в acceptance criteria."

   **d) Task найден, status=fail или escalate**:
   ```
   ✗ Workflow state: phase=<X>, status=<status>
      Last failure: <reason>
      Recovery rule (loop-recovery.md): <recovery action>
      Recommended: <recovery_command>
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "status=<status>. Подтверждаешь recovery?"
   - `header`: "Recovery"
   - `options`:
     - `label`: "Run <recovery_command> (Recommended)" · `description`: "Recovery action из loop-recovery.md."
     - `label`: "Escalate to human" · `description`: "Нужно решение owner'а — не technical."
     - `label`: "Cancel" · `description`: "Разобраться вручную перед действием."

   **e) Task complete (current_phase=done):**
   ```
   ✓ Workflow для <task-id> завершён.
      SDD status можно переводить в `implemented` (если ещё не).
      Если ещё не открыт PR — рекомендую /pdls:squash <task-id> + git push.
   ```

4. **НЕ запускай команду автоматически** — `/pdls:continue` это manual-mode resume. Жди явного `yes`.

## Правила

- Read-only по отношению к audit-trail.
- Не модифицирует SDD, evidence, или код.
- Передаёт control обратно пользователю — это **navigator**, не **driver**.

## Связи

- [`./pdls:workflow.md`](workflow.md) — full orchestration (auto-mode для R0/R1)
- [`./pdls:squash.md`](squash.md) — финальный squash перед PR
- [`${extensionPath}/scripts/workflow-state.sh`](../../${extensionPath}/scripts/workflow-state.sh) — workflow state helper
- [`../../docs/playbooks/loop-recovery.md`](../../docs/playbooks/loop-recovery.md) — recovery actions
