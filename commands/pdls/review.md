---
description: Code review агентного кода против SDD и acceptance criteria
---

Проведи review изменений: {{args}} (если не указано — review текущий diff vs origin/main).

**Mandate Review Agent (§2.11):** Read / Grep / Test only. Не вносить правки.

Шаги:
1. `git diff --name-only origin/main...HEAD` — собрать список изменённых файлов
2. Найти связанный SDD по PR title / branch name / ссылке в commit message
3. Если SDD не найден — flag это как **blocker**
4. **Java-гейт:** если среди изменённых файлов есть `*.java` — выполни блок «Java linter gate» ниже **до** заполнения чеклиста

### Java linter gate

Условие срабатывания: `git diff --name-only origin/main...HEAD | grep -q '\.java$'`.

1. Вычисли общий префикс путей изменённых `*.java` (например, все под `services/billing/` → `subpath = services/billing`). Если общего префикса нет — `subpath` пустой (весь репозиторий).
2. **Вызови команду `/pdls:java-linter-review <subpath>`** (skill `java-linter-review`) и пройди её процесс целиком, включая гейт сборки SpotBugs.
   - Токен-дисциплина (§8 GIGACODE.md): в контекст review возвращается только summary + путь к отчёту, детали остаются в `linter-reports/java-linter-<ts>.md`.
   - `/pdls:java-linter-review` не является фазой loop'а — её phase-gate transition не выполняется, управление возвращается в `/pdls:review`.
3. Если линтеры не отработали (нет JDK 17+, линтеры не вендорены, Java-исходники не найдены) — не считай это blocker'ом review, но зафиксируй в findings как **Major**: «Java-изменения не покрыты линтер-проверкой, причина: <...>».
4. Смапь smells из отчёта в findings review:

   | Severity в отчёте | Уровень в review verdict |
   |---|---|
   | High | Blocker (если в изменённых файлах) / Major (в остальном коде) |
   | Medium | Major |
   | Low | Minor |

   Учитывай только smells в файлах из diff'а; smells в незатронутом коде выноси отдельным подразделом «Pre-existing (вне scope)» и **не** учитывай в verdict.
5. В Output добавь строку со ссылкой на отчёт и агрегатом: `📄 Java linter: High <a> · Medium <b> · Low <c> → linter-reports/java-linter-<ts>.md`.

### Чеклист review

**Соответствие SDD**
- [ ] Все acceptance criteria покрыты тестами?
- [ ] Property-based invariants проверяются?
- [ ] Нет ли реализации вне scope SDD?
- [ ] Negative cases (что не должно происходить) учтены?

**Качество кода**
- [ ] Naming следует конвенциям из GIGACODE.md?
- [ ] Нет ли over-engineering (фичи "на будущее")?
- [ ] Error handling консистентен?
- [ ] Edge cases: пустые значения, лимиты, конкурентность, таймауты?
- [ ] Для Java-изменений: отработал ли Java linter gate, findings разобраны?

**AI-специфические риски (§5.1)**
- [ ] Нет ли устаревших паттернов (MD5, deprecated APIs)?
- [ ] Нет ли over-permission в IAM / file modes / network policies?
- [ ] Нет ли вызовов несуществующих библиотек (dependency hallucination)?
- [ ] Все imports реально существуют?

**Безопасность**
- [ ] Inputs валидируются?
- [ ] Нет ли утечки secrets/PII в логи?
- [ ] Auth/authz применяются ко всем новым endpoints?
- [ ] SAST findings (запусти доступный сканер)?

**Тесты**
- [ ] Тесты не модифицированы для прохождения (acceptance criteria неизменны)?
- [ ] Coverage на новом коде ≥ baseline?
- [ ] Тесты не зависят от порядка выполнения?

### Output

Выдай findings в формате:

```markdown
## Review verdict: APPROVE / REQUEST CHANGES / BLOCK

### Blockers
- <критичные проблемы>

### Major
- <серьёзные замечания>

### Minor
- <стилистические замечания>

### Positive
- <что хорошо сделано>

<!-- строка ниже — только если сработал Java linter gate -->
📄 Java linter: High <a> · Medium <b> · Low <c> → linter-reports/java-linter-<ts>.md
```

Для R3+ обязательно делегируй security check в Security subagent.

## Next step (Phase Gate)

**Phase:** `review` → `evidence | implement | plan` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))

**Запиши transition в audit-trail (ОБЯЗАТЕЛЬНО)** сразу после выдачи verdict:
```bash
bash ${extensionPath}/scripts/emit-phase-event.sh <task-id> implement review <pass|fail> <iteration> "verdict: <APPROVE|REJECT>, critical=<n>, major=<n>"
```
(`pass` — только при APPROVE; REJECT любого уровня — `fail`. `<iteration>` — текущая итерация задачи из `bash ${extensionPath}/scripts/workflow-state.sh <task-id>`, а не единица: при REJECT major цикл возвращается в `implement`, и §B обещает, что счётчик продолжается. Записанная константа обнуляла бы его ровно там, где кэп и должен сработать.)

Затем на основе review_verdict определи transition:

| verdict | critical | major | next_phase | Действие |
|---|---|---|---|---|
| APPROVE | 0 | 0 | `evidence` | См. §A |
| APPROVE | 0 | 0 (minor only) | `evidence` | См. §A |
| REJECT | 0 | ≥ 1 | `implement` | См. §B |
| REJECT | ≥ 1 | _any_ | `plan` | См. §C (architectural rollback) |

**§A — APPROVE (status=pass):**
```
✅ Review phase: APPROVE.
   Critical: 0. Major: 0. Minor: <n>.
   <краткое summary positive findings>
```

Затем **`AskUserQuestion`**:
- `question`: "Review APPROVE. Что дальше?"
- `header`: "Review→?"
- `options`:
  - `label`: "Continue → /pdls:evidence (Recommended)" · `description`: "Собрать финальный evidence bundle."
  - `label`: "Address minor findings first" · `description`: "Несколько minor правок до evidence."
  - `label`: "Stop & save" · `description`: "Сохранить state, выйти."

**§B — REJECT major (status=fail, recovery: implement):**
```
✗ Review phase: REJECT (<n> major findings, 0 critical).
   <bullets of major findings>

Recovery rule (loop-recovery.md): откат на /pdls:implement для fix'а.
   Iteration counter resumes (не сбрасывается).
```

Затем **`AskUserQuestion`**:
- `question`: "Major findings найдены. Recovery path?"
- `header`: "Reject→?"
- `options`:
  - `label`: "Back to /pdls:implement (Recommended)" · `description`: "Fix major findings в коде, iteration counter продолжает."
  - `label`: "Revise /pdls:plan" · `description`: "Findings указывают на gap в плане, не в коде."
  - `label`: "Escalate to human" · `description`: "Findings выходят за scope SDD."

**§C — REJECT critical (status=fail, recovery: plan, human required):**
```
✗ Review phase: REJECT (<n> CRITICAL findings).
   <bullets of critical findings>

⚠ Architectural rollback требуется (§9 GIGACODE.md, human required):
   Recovery rule (loop-recovery.md): откат на /pdls:sdd-new для SDD revision.
   Critical findings указывают на architectural / security gap, не на bug fixable in code.

Прежде чем продолжить, опиши:
   - что именно ломается (race condition / IAM gap / data inconsistency / ...)
   - предложение по SDD revision (новый AC / new INV / split task)
```

Затем **`AskUserQuestion`** (это всегда manual, никакого auto):
- `question`: "Critical findings — нужен architectural rollback. Подтверди путь:"
- `header`: "Critical!"
- `options`:
  - `label`: "Rollback → /pdls:sdd-new (Recommended)" · `description`: "Revise SDD: новый AC / INV / split task."
  - `label`: "Escalate to human (CAB)" · `description`: "R5-уровень: change advisory board / security officer."
  - `label`: "Halt task" · `description`: "Остановить полностью, требуется отдельное решение."

**Fallback для всех трёх блоков** (vendor без picker'а): напечатай numbered options и жди INPUT.

**Не запускай `/pdls:evidence` / `/pdls:implement` / `/pdls:sdd-new` автоматически.** Жди выбора пользователя.

**Tip (resume):** если прервался посреди задачи — `/pdls:continue <slug>` восстановит state из audit-trail.
