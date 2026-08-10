---
description: Автоматически определить risk class задачи (R0–R5)
---

Определи risk class для задачи: {{args}}

Согласно §4.5 AI DISRUPT PDLC v3.5, **risk class вычисляется автоматически** из четырёх входных параметров, а не выбирается инженером (отсекает approval fatigue).

### Шаги

1. Проанализируй задачу по четырём осям:

**a) Data classification**
- `public` — публичная информация
- `internal` — внутренняя, не критичная
- `pii` — персональные данные пользователей
- `secret` — токены, ключи, credentials
- `regulated` — финансовые транзакции, медицинские записи

**b) SDLC stage target**
- `dev` — только локальная среда
- `staging` — тестовая среда
- `prod` — продакшн

**c) Blast radius**
- `local` — один файл / модуль
- `service` — один сервис
- `multi-service` — несколько сервисов
- `platform` — общая инфраструктура / shared lib

**d) Regulatory perimeter**
- `none` — нет регуляторных требований
- `gdpr` / `pci-dss` / `dora` / `sox` — конкретные регуляции

2. Примени матрицу:

| Условия | Class |
|---|---|
| public + dev + local + none | R0 |
| internal + dev/staging + local/service + none | R1 |
| internal + staging + service + none, с feature flag | R2 |
| pii ИЛИ auth-related ИЛИ infra + prod-bound | R3 |
| secret ИЛИ prod data ИЛИ migrations ИЛИ IAM | R4 |
| regulated + любая регуляция | R5 |

**Правило тай-брейка:** при пограничном случае — выбирать **выше**.

3. Вывод:

```markdown
## Risk classification

**Class:** R<N>

**Обоснование:**
- Data: <classification>
- Stage: <stage>
- Blast radius: <radius>
- Regulatory: <perimeter>

**Permission ladder consequences (§4.5):**
- Autonomy: <Auto | Auto with hooks | PR + review | Draft + security review | Human approval + SoD | Change advisory>
- Required reviewers: <list>
- Audit depth: <JSONL | + PR evidence | + change advisory package>

**Recommended next step:** <создать SDD / эскалировать к security / делегировать в subagent>
```

4. **Активируй risk-aware хуки (ОБЯЗАТЕЛЬНО).** Запиши класс в состояние harness:

```bash
bash .gigacode/scripts/set-risk-class.sh R<N> "<однострочное обоснование>"
```

Без этого шага четыре хука (destructive-command-blocker, cost-circuit-breaker, context-integrity-review, jsonl-audit-sink) не видят класс и работают по дефолтным правилам — вся эскалация R2+/R3+ остаётся выключенной.

5. Зафиксируй risk_class в SDD и в evidence bundle.
