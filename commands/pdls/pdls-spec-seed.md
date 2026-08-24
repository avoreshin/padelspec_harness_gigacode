---
description: Сгенерировать capability-спеку (базу знаний) из кода — reverse-сеятель specs-layer (стратегия S2)
---

Сгенерируй **спеку-кандидат** из кода модуля: {{args}} (путь к модулю; если не указан — спроси).

**Origin:** портирован из workspace-репо (SDD `20260821-pdls-spec-seed-spike`, R2 spike). **Namespace:** `pdls`.

> Механизм — **стратегия S2**: статический грунт + LLM достраивает невидимые рёбра + Review-агент гейтит галлюцинации. Primary output — **проза-спека**, не граф. LLM работает только здесь (на вызове команды), не в phase-gate loop — **INV-3 соблюдён**.
> Вывод — **кандидат** в `.kb/specs/`. В источник правды `specs/` его сворачивает forward `archive` — эта команда в `specs/` **не пишет** (INV-5).

## Пайплайн

### 1. Scaffold + Decompose
```bash
bash ${extensionPath}/scripts/pdls-spec-seed.sh scaffold
bash ${extensionPath}/scripts/pdls-spec-seed.sh discover <path>   # репо/много package'ей → capability-кандидаты
```
`discover` детерминированно (без LLM) бьёт репо на capability по package-декларации. **Шаги 2–5 выполняются в цикле по каждому кандидату.** Для одного модуля/сервиса — одна итерация. Большую capability не сливай в одну гигантскую спеку — дели по bounded-context.

### 2. Explore (субагент `explore`, read-only)
Делегируй в **Explore Agent** сбор контекста по модулю. Запроси context brief:
- публичные классы / методы / сигнатуры + `file:line`;
- аннотации (`@Service`, `@Transactional`, `@EventListener`, DI-конструкторы);
- публикации/подписки событий, route→handler, callback-регистрации;
- **не** делать выводов о реализации — только факты с координатами.

> Token discipline (§7 SDD): объёмное чтение кода — внутри субагента; в основной контекст только summary + `file:line`.

### 3. Synthesize (LLM)
Из brief собери `.kb/specs/<capability>.md` в формате `capability-spec.schema.json`:
- **Metadata**-таблица: `capability` (kebab-case), `version` (`0.1.0`), `status: draft`, `last_update`;
- секция `## Requirements` с `### REQ-N: <title>` в Given-When-Then;
- каждое REQ — с inline-строкой `> anchor: <path>:<line>` на источник;
- **рантайм-wired** поведение (Spring DI, publish→listener, `@Transactional` rollback, AOP), которое не выводится статически, — помечай `> ⚠ unverified: <почему> ` с указанием evidence (какие файлы дают основание);
- секция `## Dependencies` — **прозой** перечисли соседние capability, от которых зависит эта (общие события/типы/вызовы): `- <sibling> — <за что зависит>`. Это **не** граф: навигируемых рёбер нет, только текстовые cross-refs для чтения агентом;
- секция `## Invariants` с `**INV-N**` при наличии.

Гранулярность capability: `discover` даёт границу по package; один публичный фасад/сервис = одна capability; крупный bounded-context дели на несколько файлов.

### 4. Review (субагент `review`, Read/Grep)
Делегируй в **Review Agent** проверку кандидата против кода:
- каждое REQ должно выводиться из указанного `anchor`; **без резолвящегося anchor'а** → пометить `unverified` или удалить;
- никаких утверждений, не подтверждённых кодом (анти-галлюцинация, INV-2);
- verdict findings — как в `${extensionPath}/agents/review.md`.

### 5. Guardrails (детерминированно, без LLM)
```bash
bash ${extensionPath}/scripts/pdls-spec-seed.sh validate .kb/specs/<capability>.md   # схема (exit 0 обязателен)
bash ${extensionPath}/scripts/pdls-spec-seed.sh verify   .kb/specs/<capability>.md   # anchor'ы резолвятся
```
Если `validate`/`verify` падают — вернись к шагу 3/4, не отдавай кандидат.

### 6. Manifest (после всех capability)
```bash
bash ${extensionPath}/scripts/pdls-spec-seed.sh manifest   # индекс .kb/specs/*.md (таблица + Dependencies) → .kb/manifest.md
```
`manifest` — точка входа для агента: список capability + их прозаические зависимости.

## Output
- Путь к `.kb/specs/<capability>.md` + краткое summary: сколько REQ, сколько `unverified`.
- Явно укажи: это **кандидат**, для попадания в `specs/` нужен forward `archive`.
- **Не** запускай `archive` и **не** пиши в `specs/` автоматически.

## Ограничения (§2, §9 SDD)
- ❌ Не строить граф знаний как артефакт — primary output проза-спека.
- ❌ Не писать в `specs/` в обход `archive` (INV-5).
- ❌ Не выдавать незаякоренное утверждение за факт (INV-2).
- Стек PoC — JVM (Java + Kotlin / Spring); прочие языки вне scope спайка.
