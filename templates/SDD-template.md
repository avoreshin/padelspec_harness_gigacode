# SDD: <Название фичи / задачи>

> **Software Design Document** — первичный артефакт разработки
> Спецификация ценнее кода. Код генерируется из этого документа.

---

## Metadata

| Поле             | Значение                                    |
| ---------------- | ------------------------------------------- |
| **ID**           | SDD-YYYYMMDD-<slug>                         |
| **Author**       | <имя>                                       |
| **Reviewers**    | <SME, security, architect>                  |
| **Status**       | draft / approved / implemented / deprecated |
| **Risk class**   | R0 / R1 / R2 / R3 / R4 / R5                 |
| **Story**        | <ключ(и) задачи трекера через запятую>      |
| **Created**      | YYYY-MM-DD                                  |
| **Last update**  | YYYY-MM-DD                                  |
| **Related ADRs** | <ссылки>                                    |

---

## 1. Goal (Что и зачем)

<Одно предложение: какую проблему решаем и для кого.>

**Бизнес-контекст:** <ссылка на тикет / OKR / стратегию>

**Why now:** <почему именно сейчас, какая стоимость отсутствия фичи>

## 2. Non-goals (Что НЕ делаем)

- ❌ <явное ограничение scope>
- ❌ <вещи, которые могут показаться частью задачи, но не входят>

## 3. User stories

### US-1: <название>

**Как** <роль>
**Я хочу** <действие>
**Чтобы** <ценность>

## 4. Acceptance criteria (Given-When-Then)

### AC-1: <happy path>

```gherkin
Given <начальное состояние>
When <действие>
Then <ожидаемый результат>
And <дополнительные проверки>
```

### AC-2: <error path>

```gherkin
Given <начальное состояние>
When <некорректное действие>
Then <ожидаемая ошибка>
```

### AC-3: <edge case>

```gherkin
...
```

## 5. Property-based invariants

Свойства, которые **всегда** должны выполняться (для fuzzing / property-based tests):

- **INV-1:** <инвариант, например: "сумма транзакций до и после операции совпадает">
- **INV-2:** <идемпотентность: повторный вызов с тем же request_id не создаёт дубль>
- **INV-3:** <безопасность: ни одна операция не выполняется без валидного auth token>

## 6. API contract

```yaml
# OpenAPI / gRPC / другая формальная спецификация
endpoint: POST /api/v1/<resource>
request:
  required: [field1, field2]
  properties:
    field1: { type: string, maxLength: 255 }
response:
  200: <schema>
  400: <error schema>
  401: <unauthorized>
```

## 7. Non-functional requirements

| Категория     | Требование                                 | Метод проверки        |
| ------------- | ------------------------------------------ | --------------------- |
| Performance   | p99 latency < 200ms @ 1k RPS               | Load test             |
| Availability  | 99.9%                                      | SLO monitoring        |
| Security      | Все inputs валидируются, нет SQL injection | SAST + property tests |
| Privacy       | PII шифруется at-rest и in-transit         | Code review + scanner |
| Observability | Structured logs + metrics + traces         | Manual review         |

## 8. Risk class и обоснование

**Класс:** R<N>

**Обоснование:**

- Data classification: <public / internal / PII / secret>
- SDLC stage target: <dev / staging / prod>
- Blast radius: <один сервис / несколько / платформа>
- Регуляторные перехваты: <нет / GDPR / PCI DSS / DORA>

**Следствия по permission ladder:**

- <Auto / PR review / Mandatory security review / Human approval + SoD>

## 9. Negative cases (явные не-должно-быть)

Перечислить поведение, которое **запрещено**:

- ❌ Не разрешать <операция> когда <условие>
- ❌ Не возвращать <данные> в <контекст>
- ❌ Не делать <side effect> при <состояние>

## 10. Dependencies

- **Внутренние:** <сервисы, модули>
- **Внешние:** <библиотеки с версиями, third-party API>
- **Инфраструктурные:** <БД, очереди, секреты>

## 11. Out of scope

Что **сознательно** не включено и почему:

- <фича X — отложена до v2 потому что …>

## 12. Open questions

Вопросы, требующие решения **до** реализации:

- [ ] <вопрос 1>
- [ ] <вопрос 2>

## 13. Definition of Done

Задача считается выполненной только при:

- [ ] Все acceptance criteria покрыты автоматическими тестами и тесты проходят
- [ ] Property-based tests запущены ≥1000 итераций без failure
- [ ] Security scan без High/Critical findings
- [ ] Documentation обновлена (README, ADR если есть)
- [ ] Evidence bundle сформирован и приложен к PR
- [ ] Risk-appropriate review пройден (по §3 GIGACODE.md)

## 14. Traceability

Заполняется, когда SDD описывает уже написанный код (`/pdls:spec-from-commit`); для
forward-спеки секция остаётся пустой до реализации.

- `> commit: <полный sha> — <subject>` на каждый коммит, из которого выведена спека.
  Только неизменяемый hex-SHA: `HEAD` и имя ветки указывают на движущуюся цель, и
  `pdls-spec-from-commit.sh verify` их отвергает.
- `> anchor: <path>:<line>` на ключевые места кода — по ним `verify` ловит дрейф.
- `> ⚠ unverified: <почему>` на выводимое, но статически недоказуемое поведение.
