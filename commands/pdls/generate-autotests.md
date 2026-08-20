---
description: Генерирует Cucumber feature-файлы (#language:ru) из тест-кейсов Zephyr TAF в проекте orchestrator-autotest — конвертирует Test Script в существующие step definitions, группирует по компоненту в core/ или debug/, проставляет тег @TAF-Txxxx для трассировки
---

Сгенерируй автотесты по тест-кейсам: {{args}} (ключи `TAF-Txxxx` через запятую либо ссылка на тест-кейс).

**Тип задачи:** утилита тестировщика, **R1** — пишет только локальные файлы под git. Вне PDLC-loop'а, phase-gate transition не выполняется.

Выполни skill `autotest-generator`. Полная спецификация — в `${extensionPath}/skills/autotest-generator/SKILL.md`.

## Preflight — обязателен, до любой генерации

| Проверка | Как |
|---|---|
| Проект собирается Maven | `pom.xml` в корне рабочего каталога |
| Step definitions есть | найден хотя бы один `src/main/java/**/stepdefs/*StepDefinitions.java` |
| Каталог feature-файлов есть | `<FEATURES_ROOT>` найден и содержит `core/` либо `debug/` |
| Jira MCP настроен и живой | живой вызов `zephyr_get_test_case()` по первому ключу из аргументов |

Проверка не прошла — **останови работу** и перечисли **всё** недостающее сразу, а не по одному пункту за запуск. Ничего не создавай. Текст отказа — в skill'е.

Два места, где легко ошибиться:

1. Step definitions лежат в `src/main/java/`, **не** в `src/test/java/`. С неверным путём preflight отвергнет правильный проект.
2. `<FEATURES_ROOT>` определяется **поиском**, а не константой: `src/main/resources/features/`, затем `src/test/resources/features/`, затем `features/`. Первый найденный с подкаталогом `core/` или `debug/` — рабочий.

## Процесс

1. Preflight.
2. `export PDLC_ALLOW_TEST_EDIT=1` — **безусловно**, независимо от найденного пути (обоснование в skill'е).
3. Извлечь ключи TC из аргументов.
4. Для каждого TC — `zephyr_get_test_case()`. Источник истины Jira, а не `docs/testcases/*.yaml`: TC могли отредактировать в Zephyr после создания.
5. Сгруппировать по компоненту: Orchestrator, Kafka, Enricher, Ignite SE → `core/`; Connector, SmartVista/CPS, Rule Engine, PKB Adapter → `debug/`.
6. Найти существующий feature-файл группы: есть → добавить сценарии, нет → создать по шаблону с `#language:ru` первой строкой.
7. Конвертировать Test Script в Gherkin по таблице mapping; тег `@TAF-Txxxx` обязателен на каждом сценарии.
8. Сверить каждый шаг с `src/main/java/**/stepdefs/*StepDefinitions.java`. Ненайденный шаг **не выдумывать** — вынести в отчёт с оговоркой, что он может приходить из внешнего `fraud-plugin v3.5.15`.
9. Записать файлы, выдать команду запуска.

## Output (в чат)

```
## Generate Autotests — готово
✅ <N> feature-файлов, <M> сценариев
  <FEATURES_ROOT>/core/<file>.feature
    TAF-Txxxx  <название>   @<теги>

⚠️ Шаги не найдены в локальных step definitions (<K>):
  <Class>: `* <текст шага>`  (для TAF-Txxxx)
  Возможно, из fraud-plugin v3.5.15 — проверь до добавления реализации.

Проверить diff:  git diff <FEATURES_ROOT>/
Запуск: mvn test -Dcucumber.filter.tags="@TAF-Txxxx or @TAF-Tyyyy"
```

## Next step

Проверь `git diff`, прогони `mvn test` по тегам. Недостающие step definitions — добавить вручную в соответствующий класс, предварительно убедившись, что шаг не приходит из `fraud-plugin`.
