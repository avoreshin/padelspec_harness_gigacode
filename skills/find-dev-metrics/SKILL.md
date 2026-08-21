---
name: find-dev-metrics
description: Автоматически сканирует Java/Spring Boot проект на кастомные метрики разработчиков, исключая стандартные библиотечные (Kafka, Ignite, Tomcat, Hibernate и т.д.). Генерирует metrics.md — нумерованный список метрик, сгруппированных по смыслу. Триггеры — "найди метрики", "какие метрики у нас есть", "/find-metrics".
allowed-tools:
  - Read
  - Grep
  - Glob
  - Write
  - Bash
---

# Find Developer Metrics

Автоматически обнаруживает **все кастомные метрики, созданные разработчиками** в проекте, и исключает стандартные метрики фреймворков/библиотек (Spring Boot Actuator, Kafka, Ignite, Tomcat, Hibernate и т.д.).

**Тип задачи:** автономная read-only утилита, **R1** (вне PDLC-loop'а, без обязательного evidence bundle — сам `metrics.md` является артефактом).

## Что считать «метрикой разработчика»

Метрика, которая создаётся/регистрируется явно в коде приложения через:
- `MeterRegistry.counter(name, tags...)`
- `MeterRegistry.timer(name, tags...)`
- `MeterRegistry.gauge(name, tags..., valueSupplier)`
- `MeterRegistry.distributionSummary(name, tags...)`
- `MeterRegistry.longTaskTimer(name, tags...)`
- `MeterRegistry.functionTimer(name, tags..., valueFunction)`
- `MeterRegistry.functionCounter(name, tags..., countFunction)`
- Аннотация `@Timed` (micrometer-annotations)
- Прямая регистрация через `meterRegistry.register(...)`
- Обёрточные методы: `registerCounter`, `registerGauge`, `registerHistogram`, `registerDistributionSummary`, `registerLongTaskTimer`, `updateHistogram`, `updateIntGauge`, `increment`, `incrementRequestsByDomain`
- Fluent-регистрация: `Counter.builder(...).register(meterRegistry)`

## Что НЕ считать (исключения)

| Категория | Что игнорировать |
|---|---|
| **Spring Boot Actuator** | `jvm.*`, `http.*`, `system.*`, `logback.*`, `process.*`, `uptime.*`, `disk.*` |
| **Клиент Kafka** | Метрики MBean `kafka.producer.*` (если не заведены вручную в коде как кастомные) |
| **Сервер Kafka** | Метрики MBean `kafka.server.*`, `kafka.network.*` |
| **Ignite** | MBean `ignite.*` |
| **Tomcat/Jetty/Undertow** | `tomcat.*`, `jetty.*`, `undertow.*` |
| **Hibernate** | `hibernate.*` |
| **Resilience4j** | `resilience4j.*` (если заведены автостартером Spring Boot) |
| **Micrometer internals** | `micrometer.composite.*`, `micrometer.timer.*` |
| **Health/Info** | `health.*`, `info.*`, `liveness.*`, `readiness.*` |

## Алгоритм

### Шаг 1 — Сканирование кода

Выполнить параллельный поиск по `src/`:

| Паттерн | Что даёт |
|---|---|
| `.meterRegistry\.(counter\|timer\|gauge\|distributionSummary\|longTaskTimer\|functionTimer\|functionCounter)` | Прямая регистрация через MeterRegistry |
| `.register\(` | Ручная регистрация произвольного Meter |
| `@Timed` | Аннотированные методы |
| `MeterRegistry` | Поля/параметры конструктора — найти классы-обёртки |
| `(registerCounter\|registerGauge\|registerHistogram\|registerDistributionSummary\|registerLongTaskTimer\|updateHistogram\|updateIntGauge\|increment\(\|incrementRequestsByDomain)\(` | Обёрточные методы в хелперах |
| `\.builder\(` + `(Counter\|Timer\|Gauge\|DistributionSummary\|LongTaskTimer)\.` | Fluent-регистрация |

### Шаг 2 — Сбор имён метрик

Из найденных мест извлечь имена метрик:

1. **Стринговые литералы** — `meterRegistry.counter("my.metric.name")`
2. **Константы** — `meterRegistry.counter(MY_METRIC_CONSTANT)` → разрешить до значения
3. **Конкатенация** — `name + clusterId` → собрать паттерн и префикс

### Шаг 3 — Фильтрация исключений

Сравнить собранные имена с списком исключений (см. таблицу выше). Исключить совпадения.

### Шаг 4 — Структурный снапшот

Собрать результаты Шагов 1–3 в один JSON-объект по схеме
[`dev-metrics-scan.schema.json`](../../schemas/dev-metrics-scan.schema.json)
(`project_root`, `total_custom_metrics`, `metrics_by_type`, `metrics_files`,
`unregistered_counters`, `dynamic_metrics_summary`, `excluded_library_metrics`,
`scan_metadata`) и сохранить как `{project_root}/.dev-metrics-scan.json`.
Файл транзиентный — перезаписывается при каждом запуске, целевой проект должен
добавить его в свой `.gitignore`.

Если в целевом проекте доступен harness (`.gigacode/scripts/validate-schemas.sh`
и Node.js), провалидировать снапшот перед рендером:

```
.gigacode/scripts/validate-schemas.sh validate dev-metrics-scan .dev-metrics-scan.json
```

Отсутствие validator'а/Node — не блокер (graceful no-op), просто пропусти проверку
и иди дальше к Шагу 5.

### Шаг 5 — Группировка и вывод

Сгруппировать **по смыслу** (не по типу), используя снапшот Шага 4 как источник данных.

## Генерация output-файла

По умолчанию скилл генерирует **один файл** `metrics.md` в корне проекта (рядом с `pom.xml` / `build.gradle`).

Формат — нумерованный список метрик. **Ничего больше в файле быть не должно.**

### Структура файла

```markdown
# Developer Metrics — {project_name}

- **Всего метрик:** N
- **Counter:** N | **Timer:** N | **Gauge:** N | **DistributionSummary:** N | **LongTaskTimer:** N | **FunctionTimer:** N | **FunctionCounter:** N
- **Дата сканирования:** YYYY-MM-DD

---

## Метрики входящего потока

1. **`QuantityMessagesIn`** — Счётчик входящих сообщений от оркестратора
- **Тип:** Counter
- **Описание:** Увеличивается на единицу при каждом получении нового входящего сообщения...
- **Теги:** _(нет)_
- **JMX:** ✅ — дублируется через JMX MBean
- **Prometheus:** ✅ — попадает в экспорт по пути `/actuator/prometheus`
- **Условия инициализации:** метрика создаётся на старте приложения в @PostConstruct методе `MetricsHolder.initMetrics()`

---
```

### Правила заполнения полей

| Поле | Что писать |
|---|---|
| **Тип** | Counter / Timer (quantile-гистограмма) / Timer (SLA-histogram) / Gauge (AtomicLong) / Gauge (AtomicInteger) / Gauge (double) / DistributionSummary / LongTaskTimer / FunctionTimer / FunctionCounter |
| **Описание** | Подробное описание: что фиксирует, в каких ситуациях увеличивается/уменьшается, как используется (Capacity Planning, SLA, мониторинг). Не короче 3 предложений. |
| **Перцентили** (Timer) | Список перцентилей из `TIMER_PERCENTILES` или `_(нет)_` |
| **Теги** | Список тегов через запятую, или `_(нет)_` |
| **Пример полного имени** (динамические) | Реальный пример: `QuantityMessagesSendedToEnricher_cluster1` |
| **JMX** | ✅ — если дублируется через `jmxMetrics.getXxx()`, ❌ — если нет |
| **Prometheus** | ✅ — если попадает в экспорт `/actuator/prometheus`, ❌ — если нет |
| **Условия инициализации** | Подробно: `метрика создаётся на старте приложения в @PostConstruct методе MetricsHolder.initMetrics()` / `метрика создаётся динамически для каждого кластера при инициализации кластера в методе MetricsHolder.initMetricsForCluster()`, который вызывается из `ClientsFactory.createClient()` для каждого кластера / `метрика создаётся лениво при первом вызове incrementRequestsByDomain()` / `метрика создаётся условно: на старте приложения, но только если app-name == rule-engine` |

### Группировка по смыслу

Используй следующие секции (не создавай новые, не удаляй существующие):

| Секция | Что входит |
|---|---|
| `## Метрики входящего потока` | Входящие сообщения, ошибки приёма |
| `## Метрики исходящего потока` | Исходящие сообщения, ошибки отправки |
| `## Метрики работы Enricher` | Ошибки Enricher, сообщения от Enricher |
| `## Метрики работы с Ignite` | Ошибки Ignite, ошибки вызова Ignite, таймауты Ignite, внутренние ошибки Ignite |
| `## Метрики обработки доменов` | Запросы без доменов, с несколькими доменами, без matching клиентов, по домену, ошибки подканала и невалидных доменов |
| `## Метрики производительности` | Таймеры обработки событий, таймеры вызовов кластеров, SLA-гистограммы |
| `## Метрики состояния кластеров` | Количество фактов, двойной вызов, активность кластеров |
| `## Метрики Kafka producer` | Отправленные записи, ошибки записи (JMX-backed из MBean) |
| `## Метрики rule-engine` | ALLOW, REVIEW, DENY, ERROR |

### Расположение файла

`{project_root}/metrics.md` — рядом с `pom.xml`. Перезаписывается при каждом запуске скилла.

**Важно:** В файле `metrics.md` должна быть ТОЛЬКО нумерованная последовательность метрик. Никаких дополнительных секций: «Архитектура», «JMX интеграция», «Типы таймеров», «Антипаттерны» и т.д.
