---
name: tc-from-release
description: Генерирует тест-кейсы в Jira Zephyr (проект TAF) из состава релиза UPG. Работает в два прохода — сначала черновик в docs/testcases/<release>.yaml на согласование человеку, после утверждения создаёт TC в Zephyr и привязывает к story. Триггеры — "сгенерируй тест-кейсы по релизу", "создай TC для UPG-xxxxx", "/generate-test-cases".
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
  - Edit
---

# Генерация тест-кейсов из состава релиза

Читает состав релиза в Jira, извлекает связанные story/task и порождает по ним тест-кейсы в Zephyr (проект **TAF**, `projectId=66704`).

**Тип задачи:** утилита тестировщика, **R2** — пишет во внешнюю систему, которую видит вся команда. Отсюда обязательный разрыв на согласование (см. «Два прохода»).

## Контекст проекта

Целевой проект — `orchestrator-autotest`:

- Cucumber BDD, JUnit 4, Java 11, Maven
- Zephyr в Jira: проект `TAF`, `projectId=66704`
- Link type «Состав релиза»: `id=11400`, inward — «Состоит из»
- 8 компонентов, 3 стенда (ST, ST2, IFT)
- Архитектура системы описана в `docs/harness/README.md`
- Контекст каждого компонента — в `docs/harness/modules/<component>.md`

---

## Preflight — без него не начинать

Проверить **до** любой генерации. Не прошло — остановиться, сообщить, чего не хватает, ничего не создавать. Деградированный режим не предусмотрен.

| Проверка | Как |
|---|---|
| Jira MCP настроен и живой | живой вызов `get_project("TAF")` |
| Проект TAF доступен | тот же вызов; в ответе ожидается `projectId=66704` |
| Контекст проекта на месте | каталог `docs/harness/modules/` существует и непуст |

**Почему живой вызов, а не поиск конфига на диске.** Конфигурация может присутствовать и при этом не работать: протухший токен, недоступный хост, отключённый VPN. Достоверный ответ даёт только сам вызов.

Текст отказа при недоступном MCP:

```
❌ /generate-test-cases остановлена: Jira MCP недоступен

Проверка:  get_project("TAF") → <текст ошибки>

Что нужно:
  • MCP-сервер Jira с поддержкой Zephyr, подключённый к текущему хосту
  • Сетевой доступ к https://jira.delta.sbrf.ru (VPN)
  • Права на проект TAF (projectId=66704)

Ничего не создано и не изменено.
```

Текст отказа, когда MCP работает, а контекста проекта нет:

```
❌ /generate-test-cases остановлена: не найден docs/harness/modules/

Команда запускается из корня orchestrator-autotest — рядом с pom.xml.
Текущий каталог: <pwd>

Ничего не создано и не изменено.
```

---

## Два прохода

Запись идёт наружу, в общий Jira, и откатывается только руками. Поэтому между генерацией и записью стоит человек.

```
проход 1  →  docs/testcases/<release>.yaml  →  человек читает и правит  →  проход 2  →  Zephyr
```

Проход 2 **не генерирует заново** — он читает файл. Что человек утвердил, то и создаётся, включая ручные правки.

---

## Проход 1 — черновик в файл

1. Preflight.
2. Извлечь ключ релиза из аргумента или URL.
3. `get_issue(<release>)` → релиз; `get_issue_links()` → связанные issues по link type `11400`.
4. Отфильтровать по issueType: оставить **Story** и **Task**, исключить **Bug** и **Sub-task**.
5. Для каждой story/task:
   - `get_issue()` → summary, description, acceptance criteria;
   - определить компонент (таблица триггеров ниже);
   - определить стенды;
   - прочитать `docs/harness/modules/<component>.md` — какие step definitions доступны;
   - сгенерировать 3–10 тест-кейсов.
6. Записать всё в `docs/testcases/<release-key>.yaml`.
7. Отдать путь пользователю и **остановиться**. В Jira не записано ничего.

### Требование к парсингу ключа

Связанные issue в этой инсталляции имеют вид `UPG-18405-15` — с суффиксом после номера. **Не предполагать** `^[A-Z]+-\d+$`: ключ извлекается до первого пробела или слеша, суффикс сохраняется как часть ключа и передаётся в MCP-вызовы как есть.

### Распознавание компонента

| Компонент | Триггеры | Модуль |
|---|---|---|
| Connector | `connector`, `confluent`, `http://connector` | `docs/harness/modules/connector.md` |
| Orchestrator | `orchestrator`, `event`, `JSON`, `rest` | `docs/harness/modules/orchestrator.md` |
| Enricher | `enricher`, `card-to-user-cache`, `user_id`, `Ignite`, `precondition` | `docs/harness/modules/enricher.md` |
| Rule Engine | `rule`, `правило`, `BACK ARM аналитика`, `createRule` | `docs/harness/modules/rule-engine.md` |
| SmartVista / CPS | `SmartVista`, `CPS`, `ISO8583`, `0200`, `MTI`, `adapter` | `docs/harness/modules/smartvista.md` |
| PKB Adapter | `PKB`, `pkb-adapter`, `MsgPack`, `binary` | `docs/harness/modules/pkb-adapter.md` |
| Kafka | `kafka`, `топик`, `topic`, `ConsumerRecord`, `KafkaHelper`, `FraudProducer` | `docs/harness/modules/kafka.md` |
| Ignite SE | `IGNITE Cache`, `cacheName`, `igniteService`, `IgniteService` | `docs/harness/modules/ignite.md` |

Триггеры пересекаются намеренно: `Ignite` встречается и у Enricher, и у Ignite SE; `adapter` — и у SmartVista, и у PKB. Порядок разрешения:

1. явная строка `Компонент:` в description — при её наличии триггеры не применяются;
2. иначе самый длинный совпавший триггер (`IGNITE Cache` бьёт `Ignite`);
3. при равенстве — компонент, чей модуль в `docs/harness/modules/` описывает больше совпавших сущностей.

### Разбор description story

Наблюдённая структура — bullet-list acceptance criteria плюс явные поля:

```
Enricher CARD_USERID:
  • В Ignite SE присутствует запись по ключу номера карты клиента
  • В Ignite SE отсутствует запись по ключу номера карты клиента
  • В запросе отсутствует атрибут "Номер карты клиента"
  • Значением параметра "Номер карты клиента" является большая строка
  • В запросе недекларированный тег > 10 МБ
  • В запросе присутствует пустой атрибут "Номер карты клиента"
  • В запросе неправильный тип данных — объект в числовом поле

Компонент: Enricher
Стенды: @st @ift
Приоритет: smoke
```

Правила:

- каждый `•` покрывается **минимум одним** TC; bullet уже несёт в себе positive либо negative случай — дублировать его парой не нужно;
- `Компонент:` — приоритетнее триггеров;
- `Стенды:` — теги стенда; строки нет → дефолт `@st @ift`;
- `Приоритет: smoke` → добавить тег `@smoke`.

**Соответствие не 1:1.** В наблюдённом примере 7 bullets дали 9 тест-кейсов (`TAF-T37..TAF-T45`) — часть пунктов раскрывается в несколько TC. Правило «bullet = ровно один TC» неверно; ориентир — покрыть каждый bullet, при необходимости несколькими TC.

**Story без структуры** (нет ни bullets, ни `Компонент:`) → fallback: общие TC из summary, каждый помечен в YAML комментарием:

```yaml
    # TODO: story без структурированного AC, требует ручной доработки
```

### Правила генерации TC

- один TC = один сценарий;
- покрыть все acceptance criteria story;
- precondition + 3–5 шагов + expected result на каждый шаг;
- теги: `@<component>` + стенды, плюс `@smoke` при `Приоритет: smoke`;
- имя вида `TC-NN: <что проверяем>` — нумерация сквозная в пределах story.

### Формат файла-черновика

YAML, а не Markdown: файл читают оба — человек глазами и проход 2 парсером. Свободный Markdown после ручной правки разъедется, YAML переживает редактирование.

```yaml
# Черновик тест-кейсов. Проверь, при необходимости отредактируй, затем:
#   /generate-test-cases UPG-18405 --apply
#
# Убрать лишний TC — удалить его блок. Поправить компонент — поправить labels.

release:     UPG-18405
project_key: TAF
folder:      /Релиз-UPG-18405/
generated:   2026-08-20T14:03:00
status:      draft        # draft → applied, проставляется проходом 2

test_cases:
  - story:        UPG-18405-15
    name:         "TC-01: Enricher возвращает user_id по карте"
    objective:    "Проверить корректность enricher-lookup"
    precondition: "В Ignite Cache загружена карта 2200123456789012"
    labels:       ["@orchestrator", "@enricher", "@st", "@ift"]
    steps:
      - description:     "Загрузить в Ignite карту 2200123456789012 → user_id=abc"
        expected_result: "Ключ присутствует в card-to-user-cache"
      - description:     "Отправить плоский JSON в Orchestrator, Канал=ISSUER"
        expected_result: "HTTP 200, поле «Идентификатор клиента» = abc"
```

Файл кладётся в `docs/testcases/` целевого проекта и **коммитится**: он diff-ится в PR, служит следом того, что было сгенерировано и утверждено, и переживает пересоздание сессии.

Каталог `docs/testcases/` в проекте свободен — конфликта с существующей документацией нет.

### Вывод прохода 1

```
## Generate Test Cases — черновик готов (в Jira ничего не создано)

Релиз: UPG-18405 · связанных story/task: 15 (Bug/Sub-task отфильтровано: 4)
Сгенерировано: 42 TC

  UPG-18405-15  Enricher lookup по карте       → 3 TC  (@orchestrator @enricher @st @ift)
  UPG-18405-22  Kafka publish TRIPLAN_EVENTS   → 2 TC  (@kafka @st)
  ...

📄 Черновик: docs/testcases/UPG-18405.yaml

Проверь файл, поправь что нужно, затем:
  /generate-test-cases UPG-18405 --apply
```

---

## Проход 2 — запись в Jira из файла

1. Preflight — повторно: окружение могло измениться между проходами.
2. Прочитать `docs/testcases/<release-key>.yaml`. Остановиться, если:
   - файла нет → «сначала выполни проход 1»;
   - `release` в файле не совпадает с аргументом;
   - `status: applied` → показать уже созданные ключи (см. идемпотентность);
   - YAML не парсится → указать строку. **В Jira не писать ничего.**
3. Создать папку `folder`, если её нет: `zephyr_create_folder(name=<folder>, folder_type="TEST_CASE")`.
4. Создать TC батчами по 20 с паузой 1 с между батчами.
5. Привязать TC к story: `zephyr_link_issue_to_test_cases(<story>, [<keys>])`.
6. **Записать результат обратно в файл:** `status: applied` и `key: TAF-Txxxx` в каждый блок.

Генерации на этом проходе нет.

### Идемпотентность

Получается из самого файла, без дополнительных запросов:

- `status: applied` → повторный `--apply` отказывается работать и печатает список созданных ключей;
- обратная запись ключей делает файл журналом: видно, что и во что превратилось;
- добавили story в релиз → перегенерировать черновик, проход 2 создаст только блоки без `key`.

Отсюда важное следствие: **`zephyr_search_test_cases` не является несущим**. У этого инструмента подтверждённый баг с полем `components`; он нужен максимум для перекрёстной проверки, а не для ответа на вопрос «создавали мы уже эти TC или нет».

### Вывод прохода 2

```
## Generate Test Cases — создано

✅ 42 тест-кейса: TAF-T2661..TAF-T2702
Папка: /Релиз-UPG-18405/

Привязка к story:
  UPG-18405-15 → TAF-T2661, TAF-T2662, TAF-T2663
  UPG-18405-22 → TAF-T2664, TAF-T2665
  ...

📄 Файл обновлён: docs/testcases/UPG-18405.yaml (status: applied, ключи записаны)
Ссылка: https://jira.delta.sbrf.ru/secure/Tests.jspa#/v2/testCases?projectId=66704

Дальше: /generate-autotests TAF-T2661,TAF-T2662,...
```

---

## Формат создаваемого TC

| Поле | Тип | Пример | Источник |
|---|---|---|---|
| `project_key` | String | `"TAF"` | константа |
| `name` | String | `"TC-01: Enricher возвращает user_id по карте"` | summary + description story |
| `objective` | String | `"Проверить корректность enricher-lookup"` | acceptance criteria |
| `precondition` | String | `"В Ignite Cache загружена карта"` | шаг 1 сценария |
| `labels` | List | `["@orchestrator","@st","@ift","@smoke"]` | компонент + стенды |
| `steps` | List | `[{description, expected_result}, ...]` | Test Script |

---

## MCP-инструменты

| Инструмент | Назначение | Статус |
|---|---|---|
| `get_project(key)` | preflight-проба | ✅ работает |
| `get_issue(key)` | релиз и story, все поля | ✅ работает |
| `get_issue_links()` | linked issues по типу связи | ✅ работает |
| `get_link_types()` | «Состав релиза» `id=11400` | ✅ работает |
| `search_issues(jql)` | JQL-запросы | ✅ работает |
| `zephyr_create_folder(name, folder_type)` | папка релиза | ✅ работает |
| `zephyr_create_test_case(...)` | создание TC → `TAF-Txxxx` | ✅ работает |
| `zephyr_get_test_case(key)` | чтение TC по ключу | ✅ работает |
| `zephyr_link_issue_to_test_cases(issue_key, keys)` | привязка TC к story, GET→merge→PUT | ✅ по контракту |
| `zephyr_search_test_cases(query)` | перекрёстная проверка | ⚠️ баг: TQL с полем `components` падает. Запрос строить без `components`; рабочая форма — `key in (TAF-T2661, TAF-T2662)` |

---

## Пошаговый пример

```
Вход: /generate-test-cases UPG-18405

1. get_project("TAF")                       → preflight ok, projectId=66704
2. Test-Path docs/harness/modules/          → ok, 8 модулей
3. get_issue("UPG-18405")                   → релиз «Фрод-мониторинг, спринт 42»
4. get_issue_links()                        → 19 связей, из них 15 Story/Task
5. get_issue("UPG-18405-15")                → description с bullets, Компонент: Enricher
6. Read docs/harness/modules/enricher.md    → доступные шаги Ignite + REST
7. → 3 TC на 3 bullets
   ... (× 15 story)
8. Write docs/testcases/UPG-18405.yaml      → 42 TC, status: draft
9. Стоп. Пользователь читает файл.

Вход: /generate-test-cases UPG-18405 --apply

1. get_project("TAF")                                  → preflight ok
2. Read docs/testcases/UPG-18405.yaml                  → status: draft, 42 TC
3. zephyr_create_folder("/Релиз-UPG-18405/", "TEST_CASE")
4. zephyr_create_test_case(...) × 20, пауза 1 с, × 20, пауза, × 2
5. zephyr_link_issue_to_test_cases("UPG-18405-15", ["TAF-T2661","TAF-T2662","TAF-T2663"])
   ... (× 15 story)
6. Edit docs/testcases/UPG-18405.yaml → status: applied, key на каждом блоке
```

---

## Связь с SDD

- **SDD есть** → источник acceptance criteria — SDD, TC привязаны к AC. Покрытие AC подтверждается на этапе `/generate-autotests`.
- **SDD нет** (работаем только от релиза) → источник — description story, TC привязаны к story.

## Что этот skill не делает

- Не генерирует Cucumber feature-файлы — это `autotest-generator` / `/generate-autotests`.
- Не удаляет и не редактирует уже созданные в Zephyr TC. Правка — через интерфейс Zephyr.
- Не создаёт test cycles и не запускает прогоны.
