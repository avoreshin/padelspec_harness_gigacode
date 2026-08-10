---
description: Создать новый SDD-документ из шаблона
---

Создай новую спецификацию (Software Design Document) для задачи: {{args}}

Шаги:
1. Прочитай шаблон `templates/SDD-template.md`
2. Создай файл `docs/sdd/<YYYYMMDD>-<slug>.md`, где slug — kebab-case из аргументов
3. Заполни первичные секции на основе аргументов:
   - Metadata (ID, author=current user, status=draft, created=today)
   - Goal: одно предложение
   - Non-goals: явные ограничения scope
4. Оставь Acceptance criteria, Property-based invariants, Risk class как `<TBD: requires human input>`
5. Покажи итоговый документ и собери недостающие поля.
   - **Risk class.** Вычисли класс через логику `/risk-classify` (§4.5 — risk class вычисляется автоматически из data classification / SDLC stage / blast radius / reversibility, а не выбирается вручную), затем **подтверди через `AskUserQuestion`**:
     - `question`: "Auto-classify дал risk R<n>. Подтверждаешь?"
     - `header`: "Risk class"
     - `options`:
       - `label`: "Accept R<n> (Recommended)" · `description`: "<одна строка: почему такой класс по четырём осям>."
       - `label`: "Override — выше" · `description`: "Задача рискованнее, чем показал auto-classify (при сомнении — класс выше, не ниже)."
       - `label`: "Override — ниже" · `description`: "Auto-classify переоценил; обоснование зафиксируй в SDD."
   - **Сразу после подтверждения класса** активируй risk-aware хуки (ОБЯЗАТЕЛЬНО — иначе destructive-command-blocker, cost-circuit-breaker, context-integrity-review и jsonl-audit-sink не увидят класс и эскалация R2+ не включится):
     ```bash
     bash .gigacode/scripts/set-risk-class.sh R<n> "SDD-<slug>: <однострочное обоснование>"
     ```
   - **Acceptance criteria** и **SME reviewer** — свободный ввод: в фиксированные `options` picker'а они не ложатся, поэтому спроси обычным текстовым вопросом сразу после подтверждения risk class.
   - Впиши ответы в SDD: `Metadata → Risk class`, `Metadata → Reviewers`, секция `Acceptance criteria`. Незаполненное оставляй `<TBD: requires human input>`.

   **Fallback** (vendor без picker'а): напечатай вычисленный risk class + numbered accept/override и жди INPUT.

**Не приступай к реализации** пока SDD не имеет статус `approved` от человека.

Согласно §2.5 AI DISRUPT PDLC v3.5, SDD — первичный артефакт. Код производный.

## Next step (Phase Gate)

**Phase:** `plan` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))

После создания SDD и approve от пользователя:

1. **Validate**: `bash .gigacode/scripts/validate-schemas.sh validate sdd docs/sdd/<YYYYMMDD>-<slug>.md` → exit 0. (Точечная валидация нового SDD; полный `all`-прогон — это CI-проверка всего репо, а не гейт одной задачи.) Если валидатор недоступен (exit 2 — нет node): предупреди пользователя и продолжай — это infra-проблема, не проблема SDD; sdd-schema-gate хук доловит при первой правке файла.
2. **Worktree isolation.** Задача, заведённая через `/sdd-new`, выполняется в изолированном `git worktree` — весь downstream loop (plan → test → implement) не трогает основной checkout. После approve, до перехода к фазам, спроси через **`AskUserQuestion`**:
   - `question`: "Worktree isolation для SDD-<slug> (risk R<n>)?"
   - `header`: "Worktree"
   - `options`:
     - `label`: "Create worktree (Recommended)" · `description`: ".worktrees/<slug>/ на ветке agent/<slug>; весь loop изолирован от main checkout."
     - `label`: "Work on main checkout" · `description`: "Без изоляции. Ок для R0/R1; для R2+ — отступление от §4.5 risk ladder."

   Обработка ответа:
   - **Create worktree** → запусти `bash .gigacode/scripts/agentic-worktree.sh start <slug>` **сейчас** (worktree должен существовать до фазы /test, §2.5). Активируй skill `agentic-worktree` для lifecycle. Сообщи path + branch и далее веди весь loop внутри этого worktree.
   - **Work on main checkout** + R2+ → ⚠ предупреди (worktree там required), переспроси подтверждение и зафиксируй решение в evidence bundle (open-risks).
   - Prereq: main checkout чист (`git status --porcelain` пуст) — иначе попроси commit/stash. Skill `agentic-worktree` проверяет это сам.

3. Если SDD валиден И status=approved → выведи summary:
   ```
   ✅ Plan phase: SDD-<slug> approved.
      Risk class: R<n>. AC count: <m>.
      Worktree: <.worktrees/<slug>/ на agent/<slug> | main checkout (no worktree)>
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "SDD approved. Что дальше?"
   - `header`: "SDD→?"
   - `options`:
     - `label`: "Continue → /plan (Recommended)" · `description`: "Собрать implementation plan из SDD."
     - `label`: "Skip plan → /test directly" · `description`: "Простая R0/R1 задача, идём сразу в TDD."
     - `label`: "Use /workflow (auto-mode для R0/R1)" · `description`: "Orchestrator проводит через все фазы автоматически."
     - `label`: "Stop & review SDD manually" · `description`: "Хочу ещё раз посмотреть SDD перед стартом."

4. Если SDD имеет issues (schema fail / AC=0 / risk_class=TBD):
   ```
   ✗ Plan phase: SDD incomplete — <конкретно что не так>
      Recovery: revise SDD (loop-recovery.md, строка «Plan / sdd-schema-fail»).
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "SDD incomplete. Что делаем?"
   - `header`: "SDD fix"
   - `options`:
     - `label`: "Revise SDD (Recommended)" · `description`: "Fix issues и валидировать заново."
     - `label`: "Escalate to human" · `description`: "Issues — не technical, нужно решение от owner'а."

**Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

**Не запускай `/plan` / `/test` автоматически.** Жди выбора пользователя.

**Tip (R0/R1):** для авто-режима через все фазы — используй `/workflow <slug>` вместо ручного `/plan`. См. [`workflow.md`](workflow.md).

**Tip (resume):** если прервался посреди задачи — `/continue <slug>` восстановит state из audit-trail.
