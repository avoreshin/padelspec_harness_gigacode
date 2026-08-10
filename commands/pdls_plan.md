---
description: Построить implementation plan из SDD (read-only)
---

Построй implementation plan для: {{args}}

**Режим:** read-only. На этом шаге запрещены любые изменения файлов.

Шаги:
1. Найди соответствующий SDD в `docs/sdd/` (используй Grep/Glob по аргументам)
2. Если SDD не найден или имеет статус ≠ `approved` — остановись и потребуй от пользователя создать/утвердить SDD (`/pdls:sdd-new`)
3. Прочитай SDD целиком, включая acceptance criteria и risk class
4. Изучи затрагиваемую часть кодовой базы (Explore-режим)
5. Построй план в формате:

```markdown
## Implementation Plan: <фича>

**Risk class:** R<N> (из SDD)
**SDD:** <ссылка>

### Затронутые файлы
- `path/to/file1.ext` — что меняется
- `path/to/file2.ext` — что меняется

### Шаги реализации
1. [Test] Написать failing tests для AC-1, AC-2, AC-3
2. [Impl] Реализовать <компонент A>
3. [Impl] Реализовать <компонент B>
4. [Verify] Запустить полный test suite + property tests
5. [Security] Запустить security scan для R3+

### Assumptions (требуют подтверждения)
- <предположение 1>
- <предположение 2>

### Risks
- <риск + митигация>

### Out of scope (явно)
- <что НЕ делаем в этой задаче>
```

6. Покажи план пользователю и **дождись подтверждения** перед переходом к реализации.

Для рискованных задач (R3+) задействуй subagent с security mandate для предварительной оценки.

## Next step (Phase Gate)

**Phase:** `plan` → `test` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))

После согласования плана с пользователем — выведи короткую сводку:
```
✅ Plan phase: implementation plan ready.
   Затронуто файлов: <N>. Шагов: <M>. Risk class: R<n>.
```

**Запиши transition в audit-trail (ОБЯЗАТЕЛЬНО)** — без этого `/pdls:continue` и downstream-фазы не увидят, что plan завершён:
```bash
bash .gigacode/scripts/emit-phase-event.sh <task-id> none plan pass 1 "plan ready: <N> files, <M> steps"
```
(При iterate — `from=plan`, `status=iterate`, iteration+1. Это разрешённая Bash-команда даже в read-only режиме: она пишет только в `.gigacode/audit/`, не в код.)

Если для R2+ требуется worktree — добавь предупреждение **перед picker'ом**:
```
⚠ R<n> требует worktree (.worktrees/<task-id>/).
   Запусти `bash .gigacode/scripts/agentic-worktree.sh start <task-id>` перед /pdls:test.
```

Затем **вызови инструмент `AskUserQuestion`** с такими параметрами:

- `question`: "Plan готов. Что дальше?"
- `header`: "Plan→?"
- `options`:
  - `label`: "Continue → /pdls:test (Recommended)" · `description`: "План валиден, переходим к написанию failing tests."
  - `label`: "Iterate plan" · `description`: "Доработать план; iteration counter += 1."
  - `label`: "Revise SDD" · `description`: "Plan выявил gap в SDD — возвращаемся через /pdls:sdd-new."
  - `label`: "Stop & save" · `description`: "Сохранить state в audit-trail, выйти. /pdls:continue вернёт."

В **auto-mode** (R0/R1 через `/pdls:workflow` при `status=pass`) picker пропускается, переход к `/pdls:test` автоматический. Failure / iterate всегда показывает picker (INV-3).

**Fallback для vendor'ов без `AskUserQuestion`** (Codex / GigaCode / Cursor): напечатай numbered options и жди INPUT:
```
Plan готов. Что дальше?
  1) Continue → /pdls:test (Recommended)
  2) Iterate plan
  3) Revise SDD
  4) Stop & save
```

**Не запускай `/pdls:test` автоматически.** Жди выбора пользователя.

**Tip (resume):** если прервался посреди задачи — `/pdls:continue <slug>` восстановит state из audit-trail.
