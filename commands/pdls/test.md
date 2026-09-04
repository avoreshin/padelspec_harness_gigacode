---
description: TDD — написать failing tests для acceptance criteria из SDD (Phase Gate: test phase entry)
---

Запусти TDD-фазу для задачи: {{args}} (slug SDD; опц. `--tc=gen-ASFMSTD-8441-01,gen-ASFMSTD-8441-02` — брать acceptance criteria из тест-модели релиза вместо SDD).

**Phase:** `test` (см. [`docs/playbooks/loop-state-machine.md`](../../docs/playbooks/loop-state-machine.md))
**Mandate:** написать **failing tests** из acceptance criteria, **не** касаться production-кода.

## Источник acceptance criteria

| Вход | Источник AC | Дальше |
|---|---|---|
| `{{args}}` без `--tc` | SDD в `docs/sdd/<slug>.md` | шаг 1 ниже без изменений |
| `{{args}}` с `--tc=<id>` | `docs/testcases/<release>.yaml` — файл выводится из `id` вида `gen-<release>-NN` | шаг 1 заменяется на шаг 1-TC |

Флаг опционален; без него поведение команды не меняется.

**Шаг 1-TC (вместо шага 1, если задан `--tc`).** Прочитать `docs/testcases/<release>.yaml`, найти блоки с указанными `id`, взять `objective` + `script.steps` как acceptance criteria, а `precondition` — как setup теста. Проверки: файл существует и парсится (иначе стоп с путём, где искали), каждый `id` разрешается в блок (неразрешённый — стоп со списком), блок не пустой. SDD при этом не требуется; если он есть, используется как дополнительный контекст, но источником AC остаются TC.

Внешних вызовов здесь нет: тест-модель живёт в файле под git, а не в TMS.

Для генерации Cucumber-автотестов напрямую из TC — отдельная команда `/pdls:generate-autotests`, она не проходит через phase gate.

## Процесс

1. **Identify SDD.** Если `{{args}}` пустой — попроси slug SDD. Найди файл в `docs/sdd/`. Проверь:
   - status = `approved` (если `draft` → стоп, попроси approve через `/pdls:sdd-new` или явный re-approve)
   - acceptance_criteria count ≥ 1
   - AC написаны в Given-When-Then формате
   - Если что-то не так — STOP и предложи `/pdls:sdd-new <slug>` для revision.

2. **Delegate to `test` subagent.** Используй Agent tool с `subagent_type: "test"`. Передай:
   - Полный SDD content
   - Implementation plan (если есть в diff'е от `/pdls:plan`)
   - Список acceptance criteria с IDs

3. **Validate structured output.** После того как агент завершил:
   - Найди в его ответе блок `<!-- phase-transition:json --> ... </pre>`
   - Если блок отсутствует — попроси агента дополнить (это INV-5 Phase Gate Protocol)
   - Валидируй: `bash ${extensionPath}/scripts/check-phase-transition.sh <agent-output-file>` → exit 0

4. **Record the transition (ОБЯЗАТЕЛЬНО).** Запиши phase_transition в audit-trail:

   ```bash
   bash ${extensionPath}/scripts/emit-phase-event.sh <task-id> plan test <status> 1 "<коротко: N failing tests / причина fail>"
   ```

   (`<status>` — из structured output шага 3; при self-loop test→test используй `from=test`, `status=iterate` и iteration+1. Повтор той же фазы — это `iterate` по `phase-transition.schema.json`; `fail` означает откат на предыдущую, и с ним `workflow-state.sh` порекомендует `/pdls:sdd-new`, а не ещё одну попытку.) Без этой записи `/pdls:continue` и `/pdls:squash` не увидят фазу.

5. **Read structured output** и определи следующий шаг:

   | status | next_phase | Действие пользователю |
   |---|---|---|
   | `pass` | `implement` | См. «Next step» §6 ниже |
   | `fail` | `plan` | Tests passing immediately (weak AC) → recovery prompt §7 |
   | `escalate` | `plan` | Не могу написать test (abstract AC) → mandatory human prompt §7 |
   | `iterate` | `test` | Случайно тронул src/ → revert + retry prompt §7 |

6. **Next step (status=pass):**

   Выведи summary:
   ```
   ✅ Test phase passed.
      <N> failing tests added, all targeting AC-1..AC-<N>.
      Iteration: 1.
      Files created: <list>
   ```

   Затем **вызови `AskUserQuestion`**:
   - `question`: "Failing tests готовы. Что дальше?"
   - `header`: "Test→?"
   - `options`:
     - `label`: "Continue → /pdls:implement (Recommended)" · `description`: "Тесты валидны и failing, переходим к минимальной реализации."
     - `label`: "Add more tests" · `description`: "Покрытие AC неполное, добавить ещё failing тесты."
     - `label`: "Stop & save" · `description`: "Сохранить state в audit-trail, выйти. /pdls:continue вернёт."

   **Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

   В auto-mode (R0/R1 через `/pdls:workflow` при status=pass) переход к `/pdls:implement` автоматический.

   **Не запускай `/pdls:implement` автоматически в manual-mode.** Жди выбора.

7. **Recovery (status≠pass):**

   Прочитай рекомендованный action из [`docs/playbooks/loop-recovery.md`](../../docs/playbooks/loop-recovery.md). Выведи:

   ```
   ✗ Test phase: <status>
      Reason: <reason из structured output>
      Recovery rule (loop-recovery.md, строка X): <action>
      Recommended command: /<next-phase> <slug>
   ```

   Затем **вызови `AskUserQuestion`**:
   - `question`: "Test phase: <status>. Подтверждаешь recovery?"
   - `header`: "Recover?"
   - `options`:
     - `label`: "Recover → /<next-phase> (Recommended)" · `description`: "Выполнить action из loop-recovery.md."
     - `label`: "Retry /pdls:test" · `description`: "Дать тестовому агенту ещё одну попытку."
     - `label`: "Escalate to human" · `description`: "Acceptance criteria неоднозначны или требуют архитектурного решения."

   **Fallback** (vendor без picker'а): напечатай numbered options и жди INPUT.

   Если status=escalate — добавь в конец явный alert:
   ```
   ⚠ Этот случай требует human input (§9 GIGACODE.md):
   - <конкретный escalation trigger>
   Не двигайся дальше без явного решения пользователя.
   ```

## Правила (cross-ref агент'а `${extensionPath}/agents/test.md`)

- Каждое acceptance criterion → ≥ 1 test
- Включить negative cases
- Для R3+ доменов — security/edge-case tests
- Тесты должны **падать** после написания (red-green-refactor)
- **Никогда** не подгонять тест под код
- **Не модифицировать** production-код (`src/`, `lib/`, `app/`)

## Привязка к Phase Gate Protocol

- State machine §6 of SDD-20260522-phase-gate-protocol: `test` принимает transition только из `plan`; не позволяй skip.
- Iteration counter: при первом входе = 1; self-loop test→test увеличивает.
- Audit-trail: command эмитит `phase_transition` event с `from: plan, to: test` — **явным вызовом `bash ${extensionPath}/scripts/emit-phase-event.sh` (шаг 4)**. jsonl-audit-sink пишет только tool-события и фазовые переходы не эмитит.

**Tip (resume):** если прервался посреди задачи — `/pdls:continue <slug>` восстановит state из audit-trail.
