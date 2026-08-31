---
description: Подсчитать метрики Autonomy / Quality / Cost / Trust из JSONL audit trail
---

Сгенерируй отчёт по четырём категориям метрик AI DISRUPT PDLC v3.5 §6.7 на основе append-only audit trail в `.gigacode/audit/*.jsonl`.

Аргументы: {{args}} (опционально — `--since YYYY-MM-DD`, `--task <task_id>`, `--format text|json`).

## Шаги

1. **Собрать input.** По умолчанию — все файлы в `.gigacode/audit/*.jsonl` за последние 30 дней. Если задан `--since` — от этой даты. Если `--task` — фильтр по `task_id` из evidence-bundle, привязанного к записям. Использовать `cat` + `jq -c '. | select(...)'`.

2. **Посчитать четыре категории.**

   ### Autonomy
   - `no_intervention_ratio`: доля записей с `decision=allow` от общего числа tool calls
   - `avg_session_length_minutes`: средняя длительность сессии между Start и Stop событиями
   - `avg_subagent_depth`: средняя вложенность subagent вызовов

   ### Quality
   - `test_pass_rate`: доля задач, где evidence bundle имел `tests.status=passed`
   - `regression_frequency`: % PR с failing tests, починенных в течение 7 дней
   - `evidence_completeness`: доля задач, прошедших schema validation без warnings

   ### Cost
   - `tokens_per_task_avg`: среднее `token_usage.input + output` на задачу
   - `usd_per_task_avg`: среднее `estimated_cost_usd`
   - `context_budget_utilization_avg`: среднее отношение consumed/budget из ladder

   ### Trust
   - `auto_approve_rate`: % tool calls без human review (важно для калибровки approval fatigue, §5.4)
   - `intervention_rate`: `human_interventions / total_tasks`
   - `hook_block_rate`: % decision=block от total tool calls
   - `context_drift_rate`: % PreCompact snapshots, в которых risk class менялся между фазами

3. **Сегментировать по risk_class.** Та же четвёрка метрик, но разбитая на R0/R1/R2/R3/R4/R5.

4. **Сформировать отчёт.** Default — markdown-таблица в stdout. При `--format json` — структура соответствует `metrics_snapshot` из `schemas/evidence-bundle.schema.json`.

5. **Подсветить аномалии.**
   - `hook_block_rate > 5%` за период — флаг, что что-то систематически нарушает policy.
   - `auto_approve_rate > 90%` — флаг approval fatigue (§5.4).
   - `context_drift_rate > 10%` — флаг, что классификация рисков нестабильна.
   - `context_budget_utilization > 80%` для большинства задач — флаг, что budget недостаточен или задачи раздуты.

6. **Записать снимок** в `.gigacode/.metrics/<YYYY-MM-DD>.json` для исторического тренда.

## Output template (text)

```
AI DISRUPT PDLC v3.5 — Metrics Report
Period: <since> → <now>
Tasks: <N>   Tool calls: <M>   Sessions: <S>

┌──────────┬──────────────────────────────────┬──────────┐
│ Category │ Metric                           │ Value    │
├──────────┼──────────────────────────────────┼──────────┤
│ Autonomy │ no_intervention_ratio            │ 0.74     │
│          │ avg_session_length_minutes       │ 47       │
│          │ avg_subagent_depth               │ 2.3      │
│ Quality  │ test_pass_rate                   │ 0.91     │
│          │ regression_frequency             │ 0.04     │
│          │ evidence_completeness            │ 0.97     │
│ Cost     │ tokens_per_task_avg              │ 215_000  │
│          │ usd_per_task_avg                 │ $0.28    │
│          │ context_budget_utilization_avg   │ 0.42     │
│ Trust    │ auto_approve_rate                │ 0.68     │
│          │ intervention_rate                │ 0.12     │
│          │ hook_block_rate                  │ 0.018    │
│          │ context_drift_rate               │ 0.03     │
└──────────┴──────────────────────────────────┴──────────┘

Anomalies: none
```

## Правила

- Read-only по audit trail. Никогда не модифицируй JSONL.
- Не разглашать содержимое evidence bundle сверх агрегатов.
- Snapshot в `.gigacode/.metrics/` — append-only, не перезаписывать.
- Если audit trail пуст или меньше 10 записей — не считать метрики, сказать «insufficient data, run at least 10 tasks first».

## Связи

- Source: `.gigacode/audit/*.jsonl` (заполняется `hooks/jsonl-audit-sink.sh`)
- Schema: `schemas/evidence-bundle.schema.json` (поле `metrics_snapshot`)
- PDLC §6.7 — четыре категории Autonomy/Quality/Cost/Trust
- PDLC §5.4 — approval fatigue (auto_approve_rate)
