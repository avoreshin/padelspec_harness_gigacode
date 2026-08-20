---
description: Сканирует Java/Spring Boot проект на кастомные метрики разработчиков (Micrometer) и генерирует metrics.md — нумерованный список, сгруппированный по смыслу, без библиотечного шума (Kafka/Ignite/Tomcat/Hibernate и т.д.)
---

Проанализируй Java-код текущего проекта на кастомные метрики разработчиков: {{args}} (опц. subpath для сужения области; пусто — весь репозиторий).

**Тип задачи:** автономная read-only утилита, **R1** (вне PDLC-loop'а, без обязательного evidence bundle — сам `metrics.md` является артефактом).

## Процесс

Выполни skill `find-dev-metrics`:

1. Скан кода (`src/`) на регистрацию Micrometer-метрик (прямые вызовы `MeterRegistry`, `@Timed`, обёрточные `registerXxx`/`updateXxx`, fluent-builder).
2. Извлечение имён метрик (литералы, константы, конкатенация с динамическим суффиксом).
3. Фильтрация библиотечных метрик (Actuator/Kafka/Ignite/Tomcat/Hibernate/Resilience4j/Micrometer internals/Health) по списку исключений скилла.
4. Структурный снапшот `.dev-metrics-scan.json` по схеме `${extensionPath}/schemas/dev-metrics-scan.schema.json` (опционально валидируется `${extensionPath}/scripts/validate-schemas.sh validate dev-metrics-scan .dev-metrics-scan.json`, если доступен harness/Node).
5. Рендер `metrics.md` в корне проекта (рядом с `pom.xml`/`build.gradle`) — нумерованный список метрик, сгруппированный по смыслу. Перезаписывается при каждом запуске.

Полная спецификация полей и группировки — в самом skill'е (`${extensionPath}/skills/find-dev-metrics/SKILL.md`).

## Output (в чат)

```
## Find Dev Metrics — summary
Файлов Java просканировано: <N>
Метрик найдено: <N> (Counter <a> · Timer <b> · Gauge <c> · DistributionSummary <d> · LongTaskTimer <e> · FunctionTimer <f> · FunctionCounter <g>)
Исключено библиотечных: <N>
📄 Отчёт: metrics.md
```

**Примечание:** команда не является фазой loop'а — phase-gate transition не выполняется.
