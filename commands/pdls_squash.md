---
description: Squash atomic commits задачи в один логический коммит перед PR
---

Squash коммиты задачи: {{args}}

**Source SDD:** docs/sdd/20260523-workflow-orchestration.md (R1, implemented)

## Процесс

1. **Validate context:**
   - Получи task_id из `{{args}}`. Если пустой — попроси.
   - Запусти `git rev-parse --abbrev-ref HEAD` — текущая ветка.
   - **Hard error если на main:** "squash на main запрещён, переключись на feature branch".
   - Запусти `bash .gigacode/scripts/workflow-state.sh <task-id>` — проверь, что фаза = `evidence` или `done` (squash до финала загрязняет state).
   - Если `current_phase != evidence|done` → STOP, предложи `/pdls:continue <task-id>` сначала.

2. **Найди базу squash:**
   ```bash
   MERGE_BASE=$(git merge-base origin/main HEAD)
   ```
   Это commit, от которого пошла feature branch.

3. **Покажи commits, которые будут squash'ed:**
   ```bash
   git log --oneline ${MERGE_BASE}..HEAD
   ```

   Вывод пользователю:
   ```
   Squash candidates на ветке <branch>:
     abc1234 feat: implement AC-1
     def5678 fix: lint warnings
     ghi9012 docs: update inline comments
     ...

   Всего: <N> commits с {MERGE_BASE:0:7}..HEAD
   ```

4. **Сгенерируй aggregated commit message** в Conventional Commits format:

   Title (из SDD title):
   ```
   feat(<scope>): <SDD goal as 1 line>
   ```

   Body:
   ```
   <SDD goal expanded>

   Changes:
   - <bullet 1 derived from atomic commits>
   - <bullet 2>
   - ...

   SDD: <sdd_reference path>
   Evidence: <evidence-bundle path>
   Risk class: R<N>

   ```

5. **Покажи preview пользователю:**
   ```
   Aggregated commit message:
   ---
   <message>
   ---
   ```

   Затем **`AskUserQuestion`**:
   - `question`: "Squash <N> commits в один с этим message?"
   - `header`: "Squash"
   - `options`:
     - `label`: "Squash (Recommended)" · `description`: "git reset --soft <base> + commit с aggregated message."
     - `label`: "Правки в message" · `description`: "Отредактировать message перед squash."
     - `label`: "Cancel" · `description`: "Оставить atomic commits как есть."

6. **На `yes` — выполни squash:**

   **Dry-run mode** (если в args был `--dry-run`):
   ```bash
   echo "DRY: git reset --soft ${MERGE_BASE}"
   echo "DRY: git commit -m <message>"
   exit 0
   ```

   **Реальный squash:**
   ```bash
   git reset --soft "$MERGE_BASE"
   git commit -m "<aggregated message>"
   ```

   Output:
   ```
   ✓ Squashed <N> commits в один.
      New HEAD: <new sha> <title>
      Можно посмотреть diff: git log -1
      Откат при необходимости: git reflog → reset
   ```

7. **Push: ВСЕГДА спрашивать (settings.json `ask` ladder обработает):**

   Если branch уже на origin:
   ```
   ⚠ Branch <branch> уже на origin/<branch>.
      После squash требуется git push --force-with-lease (rewrite history).

   Recommended push:
      git push --force-with-lease origin <branch>
   ```

   Если только что squash'нули local-only branch:
   ```
   Branch <branch> локальная, push первый раз — обычный git push.

      git push -u origin <branch>
   ```

   Затем **`AskUserQuestion`** (вариант команды зависит от того, на origin ветка или нет):
   - `question`: "Запустить push сейчас?"
   - `header`: "Push"
   - `options`:
     - `label`: "Push now (Recommended)" · `description`: "`--force-with-lease` если ветка уже на origin; обычный `git push -u` для новой ветки."
     - `label`: "Push потом вручную" · `description`: "Squash сделан, push отложен."

   **Любой push** проходит через `Bash(git push*)` в `ask` ladder → GigaCode попросит ещё одно подтверждение. **Double-confirm — это намеренно** (squash + push = irreversible action).

## Negative cases

- ❌ Squash на main / release/* branch — hard error.
- ❌ Squash без проверки phase=evidence|done — STOP, рекомендуй /pdls:continue.
- ❌ Auto-push без user confirmation — INV-4.
- ❌ Squash 1 commit (нет смысла) — info-сообщение «уже один commit, squash не нужен».

## Edge cases

- **Merge commits in branch history:** если в branch есть merge commits — `git reset --soft` сохранит их. Если нужно линеаризовать — отдельная задача (rebase), не входит в `/pdls:squash`.
- **Conflicting HEAD state:** если есть uncommitted changes — STOP, попроси stash или commit.
- **Branch divergence from origin:** если local за/впереди origin — info об этом перед squash.

## Связи

- [`./pdls:workflow.md`](workflow.md) — orchestrator (рекомендует `/pdls:squash` в финале)
- [`./pdls:evidence.md`](evidence.md) — DONE секция тоже ссылается на `/pdls:squash`
- [`./pdls:continue.md`](continue.md) — resume если прервался до evidence
- `.gigacode/settings.json` `ask` ladder — confirmation для `git push`
