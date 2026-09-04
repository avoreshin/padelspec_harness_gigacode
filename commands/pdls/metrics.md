---
description: Подсчитать метрики Autonomy / Quality / Cost / Trust из JSONL audit trail
---

Сгенерируй отчёт по четырём категориям метрик AI DISRUPT PDLC v3.5 §6.7 на основе append-only audit trail в `.gigacode/audit/*.jsonl`.

Аргументы: {{args}} (опционально — `--since YYYY-MM-DD`, `--task <task_id>`, `--format text|json`).

## Шаги

1. **Собрать input.** По умолчанию — все файлы в `.gigacode/audit/*.jsonl` за последние 30 дней. Если задан `--since` — от этой даты. Если `--task` — фильтр по `task_id` из evidence-bundle, привязанного к записям. Использовать `cat` + `jq -c '. | select(...)'`.

2. **Посчитать то, что источник действительно несёт.**

   Событие трейла состоит из полей `timestamp, event, agent, tool, decision, risk_class, hook, reason, session_id, tool_use_id`; у `phase_transition` добавляются `task_id, loop, from, to, status, iteration`. Типы событий — `PreToolUse`, `PostToolUse`, `SubagentStop`, `phase_transition`. Всё, чего в этом наборе нет, посчитать по трейлу нельзя — и выдумывать значение вместо этого нельзя тем более.

   ### Autonomy
   - `no_intervention_ratio`: доля `decision=allow` от всех решений
   - `tool_mix`: распределение вызовов по `tool`
   - `subagent_runs`: число событий `SubagentStop` (это запуски, **не** глубина вложенности — вложенность в трейл не пишется)
   - `iterations_per_task`: максимальная `iteration` по каждой задаче из `phase_transition`

   ### Quality
   - `phase_pass_rate`: доля `phase_transition` со `status=pass` от всех переходов
   - `rollback_rate`: доля `status ∈ {fail, escalate}` — как часто цикл откатывался
   - `cap_hits`: задачи, дошедшие до `iteration = 3` в фазе `implement`
   - Тесты, линт и покрытие AC — **не из трейла**: они лежат в evidence bundle (`.gigacode/evidence-bundle.json`), а он один на репозиторий и перезаписывается каждой задачей. Считать по нему историю нельзя; сослаться на текущий — можно

   ### Cost
   - `task_tokens_current`: `.gigacode/.cost/task-tokens` — счётчик **текущей** задачи, который ведёт `token-usage-meter`
   - Ни `estimated_cost_usd`, ни история токенов по задачам в трейле не пишутся. Пока их туда не пишет отдельный хук, среднего «токенов на задачу» и стоимости не существует — и раздел обязан сказать это, а не показать ноль

   ### Trust
   - `hook_block_rate`: доля `decision=deny` от всех решений
   - `blocks_by_hook`: кто именно отказывал и сколько раз — по паре (`hook`, `tool`)
   - `risk_class_mix`: распределение решений по `risk_class`
   - `sessions`: число различных `session_id` (длительность сессии посчитать нечем — событий начала и конца сессии в трейле нет)

   **Чего нет в источнике вовсе.** Длительность сессий, глубина субагентов, стоимость в деньгах, история PR и регрессий, утилизация context budget. Это не «пока не реализовано» — это отсутствующие поля: любая цифра напротив них будет придуманной. Если такая метрика нужна, сначала заводится событие, которое её несёт.

3. **Сегментировать по risk_class.** Та же четвёрка метрик, но разбитая на R0/R1/R2/R3/R4/R5.

4. **Сформировать отчёт.** Default — markdown-таблица в stdout. При `--format json` — структура соответствует `metrics_snapshot` из `${extensionPath}/schemas/evidence-bundle.schema.json`.

5. **Подсветить аномалии.**
   - `hook_block_rate > 5%` за период — флаг, что что-то систематически нарушает policy.
   - `no_intervention_ratio > 90%` — флаг approval fatigue (§5.4): почти всё проходит без единого отказа.
   - `rollback_rate > 30%` — флаг, что фазы закрываются раньше, чем сходятся.
   - `cap_hits` не пуст — задачи упираются в потолок итераций: обычно это неполный SDD, а не упрямый код.

6. **Записать снимок** в `.gigacode/.metrics/<YYYY-MM-DD>.json` для исторического тренда. Файл за сегодня перезаписывается: тренд складывается из файлов по дням, а не из дописывания в один. Каталог локальный и под git не идёт.

## Output template (text)

```
AI DISRUPT PDLC v3.5 — Metrics Report
Period: <since> → <now>
Tasks: <N>   Tool calls: <M>   Sessions: <S>

┌──────────┬──────────────────────────────────┬──────────┐
│ Category │ Metric                           │ Value    │
├──────────┼──────────────────────────────────┼──────────┤
│ Autonomy │ no_intervention_ratio            │ 0.74     │
│          │ subagent_runs                    │ 152      │
│          │ iterations_per_task (max)        │ 3        │
│ Quality  │ phase_pass_rate                  │ 0.91     │
│          │ rollback_rate                    │ 0.07     │
│          │ cap_hits                         │ 1 задача │
│ Cost     │ task_tokens_current              │ 215_000  │
│ Trust    │ hook_block_rate                  │ 0.018    │
│          │ blocks_by_hook (top)             │ pii ×216 │
│          │ risk_class_mix                   │ R1 0.96  │
│          │ sessions                         │ 35       │
└──────────┴──────────────────────────────────┴──────────┘

Anomalies: none
```

## Правила

- Read-only по audit trail. Никогда не модифицируй JSONL.
- Не разглашать содержимое evidence bundle сверх агрегатов.
- Snapshot в `.gigacode/.metrics/` — один файл на день, локальный (в `.gitignore`).
- Если audit trail пуст или меньше 10 записей — не считать метрики, сказать «insufficient data, run at least 10 tasks first».

## Связи

- Source: `.gigacode/audit/*.jsonl` (заполняется `${extensionPath}/hooks/jsonl-audit-sink.sh`)
- Schema: `${extensionPath}/schemas/evidence-bundle.schema.json` (поле `metrics_snapshot`)
- PDLC §6.7 — четыре категории Autonomy/Quality/Cost/Trust
- PDLC §5.4 — approval fatigue (auto_approve_rate)
