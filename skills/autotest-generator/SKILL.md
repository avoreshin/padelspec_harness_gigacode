---
name: autotest-generator
description: Генерирует Cucumber feature-файлы (#language:ru) из тест-кейсов Zephyr TAF в проекте orchestrator-autotest. Читает Test Script каждого TC, конвертирует шаги в существующие step definitions, группирует по компоненту в core/ или debug/, проставляет тег @TAF-Txxxx для трассировки. Триггеры — "сгенерируй автотесты по тест-кейсам", "сделай feature-файл из TAF-T", "/generate-autotests".
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
  - Edit
  - Bash
---

# Генерация автотестов из тест-кейсов Zephyr

Читает тест-кейсы из Zephyr (проект **TAF**) и порождает по ним Cucumber-сценарии на русском Gherkin в `orchestrator-autotest`.

**Тип задачи:** утилита тестировщика, **R1** — пишет только локальные файлы под git, откат через `git checkout`.

---

## Preflight — без него не начинать

Нужны **обе** зависимости: Jira MCP (прочитать TC) и проект с автотестами (куда писать). Не прошло — остановиться, перечислить **всё** недостающее сразу, ничего не создавать.

| Проверка | Как |
|---|---|
| Проект собирается Maven | `pom.xml` в корне рабочего каталога |
| Step definitions есть | найден хотя бы один `src/main/java/**/stepdefs/*StepDefinitions.java` |
| Каталог feature-файлов есть | `<FEATURES_ROOT>` найден (см. ниже) и содержит `core/` либо `debug/` |
| Jira MCP настроен и живой | живой вызов `zephyr_get_test_case()` по первому ключу из аргументов |

### Путь к step definitions

`src/main/java/ru/sbrf/fraud/at/orchestrator/stepdefs/` — **не** `src/test/java/`. Это проект, где автотесты и есть продукт, поэтому раскладка отличается от привычной Maven-конвенции.

Ошибиться здесь дорого: с путём `src/test/java/` preflight падал бы **на правильном проекте** — команда отказывалась бы работать в `orchestrator-autotest`, сообщая, что это не проект с автотестами.

### Поиск `<FEATURES_ROOT>`

Каталог определяется поиском, а не константой. Порядок проверки:

1. `src/main/resources/features/`
2. `src/test/resources/features/`
3. `features/`

Первый найденный, содержащий `core/` или `debug/`, — рабочий. Ноль найденных — отказ.

Так сделано потому, что step definitions лежат под `src/main/`, и feature-файлы вполне могут быть там же. Поиск снимает неопределённость без угадывания и переживает возможный переезд каталога.

### Текст отказа

```
❌ /generate-autotests остановлена: это не проект с автотестами

Текущий каталог: C:\work\some-service

  ✅ pom.xml
  ❌ features/ с подкаталогами core|debug        — не найден ни по одному из
                                                   src/main/resources, src/test/resources, ./
  ❌ **/stepdefs/*StepDefinitions.java           — не найдено ни одного файла

Команда запускается из корня orchestrator-autotest.
Ничего не создано и не изменено.
```

При недоступном MCP:

```
❌ /generate-autotests остановлена: Jira MCP недоступен

Проверка:  zephyr_get_test_case("TAF-T2661") → <текст ошибки>

Что нужно:
  • MCP-сервер Jira с поддержкой Zephyr, подключённый к текущему хосту
  • Сетевой доступ к https://jira.delta.sbrf.ru (VPN)

Ничего не создано и не изменено.
```

---

## Активация прав на правку тестов

Вторым шагом, до любой записи:

```bash
export PDLC_ALLOW_TEST_EDIT=1
```

Паттерн `*/test/*` в `test-files-protector.sh` блокирует запись (`{"decision":"block"}`, exit 2) — но **только если `<FEATURES_ROOT>` окажется под `src/test/`**. Если каталог найдётся под `src/main/resources/features/`, хук не сработает: `*/main/*` под его паттерны не подпадает.

Переменная выставляется **безусловно**, независимо от найденного пути. Лишней она не будет: она лишь снимает блокировку, ничего не включая, а если каталог когда-нибудь переедет под `src/test/`, команда не сломается молча.

Обоснование правомерности: генерация тестов из утверждённых человеком TC **и есть** формирование acceptance criteria, а не подгонка тестов под уже написанную реализацию — то, от чего защищает хук (`.gigacode/GIGACODE.md` §2.13).

Побочное следствие того же различия путей: `*StepDefinitions.java` лежат под `src/main/java/` и хуком **не защищены**. Этот skill их и не правит — только сообщает о недостающих шагах.

---

## Процесс

1. Preflight.
2. `export PDLC_ALLOW_TEST_EDIT=1`.
3. Извлечь ключи TC из аргументов (список через запятую либо URL).
4. Для каждого TC: `zephyr_get_test_case()` → objective, precondition, Test Script, labels.
   Источник истины — **Jira**, а не `docs/testcases/*.yaml`: TC могли отредактировать в интерфейсе Zephyr после создания.
5. Группировка по компоненту — из labels; при их отсутствии из анализа Test Script.
6. Для каждой группы: найти существующий feature-файл (есть → append сценарии; нет → создать по шаблону).
7. Конвертировать Test Script → Gherkin по таблице mapping.
8. Проверка покрытия шагов — сверить с `src/main/java/**/stepdefs/*StepDefinitions.java`.
9. Записать файлы, вывести команду запуска.

### Маршрутизация по каталогам

| Компонент | Каталог |
|---|---|
| Orchestrator, Kafka, Enricher, Ignite SE | `<FEATURES_ROOT>/core/` |
| Connector, SmartVista / CPS, Rule Engine, PKB Adapter | `<FEATURES_ROOT>/debug/` |

Ignite SE отнесён к `core/` по наблюдению: `enrichers.feature` (TAF-T37..T45), где Ignite — основной участник, лежит именно там.

---

## Mapping: TC Step → Cucumber Step

<!-- SYNC-POINT: снимок step definitions orchestrator-autotest на 2026-08-20.
     При изменении *StepDefinitions в orchestrator-autotest — обновить эту таблицу.
     Проверка: сверить с src/main/java/ru/sbrf/fraud/at/orchestrator/stepdefs/ -->

| Действие в TC | Cucumber Step | Класс |
|---|---|---|
| Загрузить карту в Ignite | `* загрузить в IGNITE Cache "card-to-user-cache" ключ "..." со значениями` | `IgniteStepDefinitions` |
| Проверить наличие карты в Ignite | `* проверить наличие ключа "..." в IGNITE Cache "card-to-user-cache"` | `IgniteStepDefinitions` |
| Отправить JSON в Orchestrator | `* отправить плоский JSON запрос "event" в оркестратор с параметрами` | `RestStepDefinitions` |
| Отправить JSON в Connector | `* отправить плоский JSON запрос "event" в коннектор с параметрами` | `RestStepDefinitions` |
| Отправить ISO8583 0200 | `* отправить ISO8583 сообщение 0200 с параметрами` | `SmartVistaStepDefinitions` |
| Проверить ответ Orchestrator | `* проверить в последнем ответе оркестратора следующие поля по JPath` | `RestStepDefinitions` |
| Проверить сообщение в Kafka | `* проверяет что в топике "TRIPLAN_EVENTS" есть запись в бинарном формате` | `KafkaStepDefinitions` |
| Создать правило | `* создать правило с параметрами` | `RuleStepDefinitions` |
| Проверить метрику | `* проверяет что метрика "..." равна ...` | `MetricsStepDefinitions` |

### Полный состав step definitions проекта

Все восемь классов — в `src/main/java/ru/sbrf/fraud/at/orchestrator/stepdefs/`:

| Класс | Ответственность | Есть в mapping |
|---|---|---|
| `RestStepDefinitions` | REST-вызовы (Connector/Orchestrator), JPath-проверки, переменные | ✅ |
| `KafkaStepDefinitions` | чтение/запись топиков, бинарный формат, JPath по MsgPack | ✅ |
| `IgniteStepDefinitions` | CRUD Ignite Cache — загрузка, удаление, проверка ключей | ✅ |
| `SmartVistaStepDefinitions` | ISO8583-запросы в SmartVista/CPS, проверка MTI | ✅ |
| `RuleStepDefinitions` | CRUD правил (BACK ARM аналитика / Kafka) | ✅ |
| `MetricsStepDefinitions` | проверка метрик (Actuator / Prometheus) | ✅ |
| `PreconditionsStepDefinitions` | подготовка данных, pre-шаги | ❌ сигнатуры не перенесены |
| `UtilStepDefinitions` | переменные, паузы, конвертации, Stash | ❌ сигнатуры не перенесены |

Два последних класса использовать нельзя, пока их сигнатуры не попадут в таблицу mapping. Сценарии, которым нужны подготовительные или служебные шаги, уходят в блок «требуется добавить step definitions» и разбираются человеком.

### Осторожно: часть шагов приходит не из проекта

База Cucumber-шагов идёт из внешнего **`fraud-plugin v3.5.15`**. Проверка покрытия (шаг 8), сканирующая только `**/stepdefs/*StepDefinitions.java`, этих шагов не найдёт и выдаст ложное «требуется добавить step definitions» на каждый из них.

Поэтому формулировка предупреждения — **не** «такого шага нет», а:

```
⚠️ Шаг не найден в локальных step definitions:
     * <текст шага>
   Возможно, он предоставляется fraud-plugin v3.5.15 — проверь до того,
   как добавлять реализацию, иначе получится дубль.
```

Разница существенная: первая формулировка провоцирует написать дублирующий step definition поверх плагина, вторая — сначала проверить.

Ненайденный шаг **не выдумывать**: не подставлять похожий из таблицы и не изобретать новый текст. Сценарий записывается как есть, шаг уходит в отчёт.

---

## Шаблон feature-файла

```gherkin
#language:ru
Функционал: <краткое описание функционала>

  @<компонент> @st @ift @TAF-Txxxx
  Сценарий: TAF-Txxxx <краткое название>
    # step 1
    * <step definition>
      | Параметр | Значение |

    # step 2
    * <step definition>
      | $.['JPath'] | expected |

    # step 3 (Kafka)
    * проверяет что в топике "TOPIC_NAME" есть запись в бинарном формате с ключом "#{переменная}"
    * проверить в последнем сообщении из топика "TOPIC_NAME" следующие поля по JPath
      | $.['JPath'] | expected |
```

Конвенции, обязательные к соблюдению:

- `#language:ru` — **первая строка файла**, иначе Cucumber не разберёт кириллические ключевые слова;
- ключевые слова кириллицей: `Функционал:`, `Сценарий:`, шаги через `*`;
- теги компонентов: `@orchestrator`, `@enricher`, `@connector`, `@smartvista`, `@rule`, `@kafka`;
- теги стендов `@st` / `@ift` — по умолчанию оба;
- тег `@TAF-Txxxx` обязателен на каждом сценарии — это трассировка «автотест ↔ тест-кейс»;
- передача данных между шагами — `#{имя_переменной}` (Stash);
- JPath-проверки — `$.['Поле']`, с учётом кириллических ключей JSON.

---

## Пример конвертации

Test Script в Zephyr:

```
Step 1: Загрузить в Ignite карту 2200123456789012 → user_id=abc
Step 2: Отправить JSON в Orchestrator, Канал=ISSUER
Step 3: Проверить response.user_id == "abc"
Step 4: Проверить запись в Kafka
```

Результат:

```gherkin
@smoke @orchestrator @enricher @st @ift @TAF-T2661
Сценарий: TAF-T2661 Enricher возвращает user_id по карте
  * загрузить в IGNITE Cache "card-to-user-cache" ключ "2200123456789012" со значениями
    | user_id | abc |
  * отправить плоский JSON запрос "event" в оркестратор с параметрами
    | Канал               | ISSUER           |
    | Номер карты клиента | 2200123456789012 |
  * проверить в последнем ответе оркестратора следующие поля по JPath
    | $.['Идентификатор клиента'] | abc |
  * проверяет что в топике "TRIPLAN_EVENTS" есть запись в бинарном формате с ключом "#{ID последнего события}"
  * проверить в последнем сообщении из топика "TRIPLAN_EVENTS" следующие поля по JPath
    | $.['Идентификатор клиента'] | abc |
```

---

## Вывод

```
## Generate Autotests — готово

✅ 1 feature-файл, 3 сценария

  <FEATURES_ROOT>/core/orchestrator-enhancements.feature
    TAF-T2661  Enricher возвращает user_id           @orchestrator @st @ift
    TAF-T2662  Enricher возвращает пустой response   @orchestrator @st @ift
    TAF-T2663  Enricher по тестовому каналу          @orchestrator @st

⚠️ Шаги не найдены в локальных step definitions (1):
  KafkaStepDefinitions: `* проверить отсутствие записи в топике "..."`  (для TAF-T2663)
  Возможно, из fraud-plugin v3.5.15 — проверь до добавления реализации.

Проверить diff:  git diff <FEATURES_ROOT>/
Запуск:
  mvn test -Dcucumber.filter.tags="@TAF-T2661 or @TAF-T2662 or @TAF-T2663"
```

---

## Почему здесь нет файла-черновика

В `/generate-test-cases` черновик нужен, потому что запись идёт наружу, в общий Jira, и откатывается руками. Здесь артефакт — сами feature-файлы: они локальные, под git, просматриваются через `git diff` и откатываются одной командой. Промежуточный черновик добавил бы шаг, не добавив контроля.

## Что этот skill не делает

- Не создаёт и не редактирует тест-кейсы в Zephyr — это `tc-from-release` / `/generate-test-cases`.
- Не добавляет step definitions в Java-код. Недостающие шаги только перечисляет с предлагаемой сигнатурой.
- Не запускает `mvn test` — выдаёт готовую команду, решение за человеком.
