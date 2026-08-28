# GIGACODE.md — Operational Context for AI Agents

> Этот файл — **guidance layer** для агентов, работающих в этом репозитории.
> Согласно §2.6 AI DISRUPT PDLC v3.5, GIGACODE.md обеспечивает **вероятностное** соблюдение конвенций.
> **Compliance-критичные правила enforce-ятся через hooks и policy-as-code** (`.gigacode/settings.json`), а не через этот файл.

---

## 1. Project context

- **Стек:** <язык, фреймворк, runtime>
- **Архитектура:** <monolith / microservices / modular>
- **Критические домены:** <auth, payments, PII — список доменов R3+>
- **Не-цели:** <что мы НЕ делаем в этом репо>

## 2. Conventions

### Код
- Стиль: <ссылка на styleguide или линтер-конфиг>
- Naming: <правила именования>
- Тесты: расположение, фреймворк, обязательное покрытие для новых функций

### Git
- Trunk-based development, feature branches < 24h
- Commit message: `<type>(<scope>): <subject>` (Conventional Commits)
- PR обязательно ссылается на SDD-документ в `docs/sdd/`

### Документация
- Архитектурные решения → `docs/adr/NNNN-title.md`
- Спецификации фич → `docs/sdd/<feature>.md`

## 3. Risk classification (R0–R5)

Перед любой задачей агент **должен** определить risk class. Если не уверен — задать вопрос человеку.

| Class | Примеры в этом репо | Autonomy |
|---|---|---|
| R0 | docs, comments, formatting | Auto |
| R1 | unit tests, local refactor, non-prod код | Auto with hooks |
| R2 | feature code behind flag | PR + human review |
| R3 | auth, payments, PII, infra | Draft + mandatory security review |
| R4 | production data, IAM, migrations | Human approval + separation of duties |
| R5 | regulated risk logic | Change advisory board |

**Правило:** при сомнении — выбирать класс **выше**, не ниже.

## 4. Workflow для агентных задач

Каждая агентная задача проходит четыре фазы (см. §2.13 PDLC):

1. **Plan** — прочитать SDD, составить implementation plan, зафиксировать assumptions
2. **Test** — написать failing tests до кода (TDD)
3. **Implement** — реализовать минимальный код для прохождения тестов, **не менять тесты**
4. **Evidence** — собрать evidence bundle (см. §6)

Для запуска используй `/pdls:plan`, `/pdls:sdd-new`, `/pdls:review`, `/pdls:evidence`.

> Справочник по командам, хукам и end-to-end workflow — в README харнесса.
> Кастомизация под свой стек: [`.gigacode/docs/CUSTOMIZATION.md`](docs/CUSTOMIZATION.md).

## 5. Subagent guidelines

При делегировании в subagent:
- **Explore Agent** — read-only (Read, Grep, Glob). Возвращает context brief.
- **Plan Agent** — read-only + docs. Возвращает план + риски.
- **Test Agent** — test runners + logs. Создаёт failing tests.
- **Coding Agent** — Edit/Write в worktree, не трогает тесты.
- **Review Agent** — Read/Grep/Test. Возвращает findings.
- **Security Agent** — scanners + read-only. Возвращает security verdict.

**Запрещено:** subagent не может получить больше прав, чем parent.

## 6. Evidence Bundle (обязательный output)

Любая агентная задача завершается **только** после сборки evidence bundle:

- diff summary (изменённые файлы, +/− lines)
- выполненные команды (build, test, lint, typecheck)
- результаты тестов (passed/failed/skipped)
- security scan results
- unresolved assumptions / open risks
- risk class задачи
- ссылка на SDD и acceptance criteria

Schema: `schemas/evidence-bundle.schema.json`. Используй `/pdls:evidence` для генерации.

## 7. Что НЕ делать

- ❌ Не запускать destructive команды (`rm -rf`, `git push --force`, prod migrations) — заблокировано хуками
- ❌ Не читать/выводить secrets (`.env`, `*.pem`, `credentials.*`)
- ❌ Не объявлять задачу завершённой без evidence bundle
- ❌ Не модифицировать тесты, чтобы пройти их (это меняет acceptance criteria). Enforced хуком `test-files-protector.sh`: правки в `test/*` блокируются, пока не открыто окно правки (`bash .gigacode/scripts/test-edit-window.sh open "<причина>"`) — открывает и сразу закрывает только Test Agent.
- ❌ Не выходить за scope SDD без явного согласования
- ❌ Не игнорировать failing test «потому что он, кажется, не связан с задачей»

## 8. Token discipline

- Используй `/compact` при приближении к лимиту контекста
- Не загружай весь репо в контекст — используй targeted Grep/Read
- Verbose tool output — кандидат на subagent с возвратом summary

## 9. Эскалация к человеку

Запросить решение человека, если:
- Risk class ≥ R3
- SDD неполный или противоречивый
- Acceptance criteria недостижимы без изменения архитектуры
- Обнаружена security уязвимость, выходящая за scope задачи
- Token budget превышен на 50%+

## 10. Дисциплина инструментов

Правила про сами инструменты, а не про процесс. Оба закрывают наблюдаемый класс отказов, а не гипотетический.

- **Префикс нумерации строк не является частью файла.** Чтение файла показывает строки как `<номер>\t<текст>` — в самом файле ни номера, ни табуляции нет. Прежде чем положить прочитанный текст в правку, срежь префикс. Если правка отвечает «строка не найдена», а текст скопирован из вывода чтения, причина почти всегда эта: повторять ту же правку бессмысленно, нужно снять префикс.
- **Временные файлы — вне анализируемого каталога.** Вспомогательный скрипт, дамп или черновик, созданный внутри каталога, который сам же разбираешь, становится входом для следующего обхода и портит подсчёты, манифесты и результаты поиска. Пиши такие файлы в `/tmp`, а не рядом с данными.

---

**Owner:** <команда / роль>
**Last review:** <YYYY-MM-DD>
**Validity:** review every quarter
