---
description: Реверс-инженерить заполненный SDD из ссылок/хэшей коммитов — спека по сделанному коду (стратегия S2)
---

Собери **заполненный SDD** из коммитов: {{args}} (один/несколько commit ref/URL; если не указано — спроси).

**Origin:** портирован из workspace-репо (SDD `20260827-pdls-spec-from-commit`, R2). **Namespace:** `pdls`.

> Sibling `/pdls:spec-seed` (модуль → capability-спека). Здесь источник — **git-коммиты**, целевой
> шаблон — `${extensionPath}/templates/SDD-template.md` (schema `sdd.schema.json`), вывод — в `docs/sdd/`.
> Механизм — **стратегия S2**: детерминированный грунт из git + LLM-синтез + Review-агент против
> галлюцинаций + детерминированные guardrails. LLM работает только здесь (на вызове), не в
> phase-gate loop — **INV-3 соблюдён**.

## Пайплайн

### 1. Resolve + Task id
```bash
bash ${extensionPath}/scripts/pdls-spec-from-commit.sh resolve {{args}}   # ref/URL → полный SHA (по строке)
bash ${extensionPath}/scripts/pdls-spec-from-commit.sh task    {{args}}   # номер задачи из сообщений коммитов
```
GitHub-URL вида `.../commit/<sha>` нормализуется автоматически. Нерезолвящийся вход → exit 2, стоп.

`task` извлекает номер задачи (Jira `KEY-123` → `key-123`, GitHub `#123` → `issue-123`) из сообщений
коммитов — он попадёт в имя файла спеки. Токены формы стандарта или кодировки (`UTF-8`, `SHA-256`,
`ISO-8601`, …) отсеиваются: они совпадают с формой Jira-ключа, но задачей не являются.
Разбор результата:
- **ровно один токен** → используй его как `<task>` в имени;
- **несколько токенов** → уточни у пользователя, какой номер задачи брать (`AskUserQuestion`);
- **exit 1 (ничего не найдено)** → **спроси у пользователя номер задачи** (`AskUserQuestion`);
  если пользователь отвечает, что номера нет — используй `<task>` = `no-task`.

### 2. Surface (детерминированно, без LLM)
```bash
bash ${extensionPath}/scripts/pdls-spec-from-commit.sh surface <shas>   # сообщение, изменённые файлы, diffstat
```
Это грунт для синтеза: что затронуто, с какими сообщениями. Патчи-детали читает Explore-агент.
Merge-коммиты разбираются по первому родителю — ссылка на merge-коммит смердженного PR
даёт тот же перечень файлов, что и ссылка на сам коммит.

> Если перечень файлов пуст — не синтезируй спеку. Пустой грунт означает, что читать нечего;
> вернись к пользователю за другой ссылкой.

### 3. Explore (субагент `explore`, read-only)
Делегируй в **Explore Agent** сбор контекста по изменённым файлам. Запроси context brief:
- публичные символы/сигнатуры затронутого кода + `file:line`;
- наблюдаемое поведение (новые ветки, валидации, побочные эффекты) с координатами;
- **только факты с координатами**, без выводов о нереализованном.

> Token discipline: объёмное чтение diff/кода — внутри субагента; в основной контекст только
> summary + `file:line`.

### 4. Synthesize (LLM)
Заполни `${extensionPath}/templates/SDD-template.md` → `docs/sdd/<YYYYMMDD>-<task>-<slug>.md`
(где `<task>` — номер задачи из шага 1; `<slug>` — kebab-краткое имя из intent коммитов):
- **Metadata:** `ID: SDD-<date>-<task>-<slug>` (должен совпадать с именем файла без расширения),
  `Author`, `Status: draft` (документируем уже сделанное — человек переводит в `implemented`/`approved`),
  `Risk class` (см. `/pdls:risk-classify`), `Created`;
- **§1 Goal** — из intent коммитов; **§2 Non-goals / §9 Negative cases** — из явно не затронутого;
- **§4 Acceptance criteria** (Given-When-Then) — реверс из наблюдаемого поведения diff'а;
- **§5 Invariants** при наличии; **§8 Risk class** с обоснованием; **§13 Definition of Done**;
- секция **`## 14. Traceability`** (есть в шаблоне): на каждый коммит строка
  `> commit: <sha> — <subject>` — **полный SHA из шага 1**, не `HEAD` и не имя ветки
  (`verify` их отвергает: подвижная ссылка ничего не фиксирует) — плюс
  `> anchor: <path>:<line>` на ключевые изменения; это база для `verify`;
- выводимое-но-статически-недоказуемое поведение помечай `> ⚠ unverified: <почему>` с evidence.

### 5. Review (субагент `review`, Read/Grep)
Делегируй в **Review Agent** проверку синтезированного SDD против кода:
- каждое AC выводится из diff/anchor; без резолвящегося якоря → `unverified` или удалить;
- никаких утверждений, не подтверждённых кодом (анти-галлюцинация, INV-2).

### 6. Guardrails (детерминированно, без LLM)
```bash
bash ${extensionPath}/scripts/pdls-spec-from-commit.sh validate docs/sdd/<slug>.md   # sdd.schema.json (exit 0 обязателен)
bash ${extensionPath}/scripts/pdls-spec-from-commit.sh verify   docs/sdd/<slug>.md   # commit + anchor резолвятся
```
Если `validate`/`verify` падают — вернись к шагу 4/5, кандидат не отдавай. Причину отказа
`validate` печатает в stderr; `verify` называет каждую непрошедшую ссылку отдельной строкой.

Пути принимаются и относительно текущего каталога, и относительно корня репозитория.

## Output
- Путь к `docs/sdd/<task>-<slug>.md` + краткое summary: номер задачи, сколько AC, сколько `unverified`, какие коммиты.
- Явно укажи: `Status` оставлен `draft` — перевод в `approved`/`implemented` за человеком.

## Ограничения
- ❌ Не выдавать незаякоренное утверждение за факт (INV-2).
- ❌ Не ставить `Status: approved` автоматически.
- ❌ Не писать в `specs/` в обход forward-`archive`.
