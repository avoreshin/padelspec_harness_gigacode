# PaDeLSpec Harness — расширение для GigaCode

> ⚙️ Собрано автоматически из исходного репозитория [`pdlc-harness`](https://github.com/avoreshin/pdlc-harness). Не редактировать вручную — правки вносить в исходник.
> Версия сборки: **0.6.3** · источник: `406de1f`

Governance-обвязка **AI DISRUPT PDLC v3.5** как расширение [GigaCode](https://gigacode.ru) (Sber).
Превращает «модель пишет код» в управляемый процесс: команды `/pdls:*`, субагенты, скиллы,
детерминированные policy-хуки, phase-gate loop и обязательный **evidence-артефакт** на выходе.

Namespace команд — `pdls`. Бренд — **PaDeLSpec**.

---

## Установка

```bash
# из репозитория:
gigacode extensions install https://github.com/avoreshin/padelspec_harness_gigacode

# или локально (dev, symlink — правки видны сразу):
gigacode extensions link /путь/к/padelspec-harness-gigacode
```

Требования: `bash`, `node` (≥18, JSON-валидатор доустанавливается при первом запуске).

---

## Как пользоваться

Каждая задача проходит фазы (§2.13 PDLC), каждая фаза — команда `/pdls:*`:

| Шаг | Команда | Что делает |
|---|---|---|
| 1. Спека | `/pdls:sdd-new <slug>` | Software Design Document; 3 вопроса (risk class, AC, reviewer) |
| 2. План | `/pdls:plan <slug>` | implementation plan (read-only субагенты explore + plan) |
| 3. Тесты | `/pdls:test <slug>` | failing tests из AC (TDD; трогать `src/` запрещено) |
| 4. Код | `/pdls:implement <slug>` | минимальный код, пока тесты не зелёные (тесты неприкосновенны) |
| 5. Ревью | `/pdls:review <slug>` | сверка с SDD/AC (review + security для R3+) |
| 6. Evidence | `/pdls:evidence <slug>` | evidence bundle — задача не закрыта без него |

Оркестратор: **`/pdls:workflow <slug>`** · Возобновить: **`/pdls:continue <slug>`**.
Прочее: `/pdls:risk-classify`, `/pdls:squash`, `/pdls:metrics`, `/pdls:java-linter-review`, `/pdls:harness`.

---

## Как настраивать

- **`GIGACODE.md`** — контекст проекта: стек, конвенции, риск-классы R0–R5.
- **`gigacode-extension.json → settings.permissions`** — `deny`/`ask`/`allow` (по умолчанию: `rm -rf`, force-push, secrets/PII запрещены).
- **`gigacode-extension.json → settings.hooks`** — policy-хуки (enforce, не guidance). Вкл/выкл: `/pdls:harness hooks disable|enable <name>`.
- **`policies/risk-ladder.yaml`** — лимиты по классам R0–R5.
- **`.gigacode/`** в проекте — runtime-state (`audit/`, `.cost/`), создаётся автоматически; в `.gitignore`.

Диагностика: `/pdls:harness doctor` (пакеты + схемы) · `/pdls:harness schemas all`.

---

## Структура

```
gigacode-extension.json   # манифест (name=pdls, contextFileName=GIGACODE.md, settings{permissions,hooks})
GIGACODE.md · commands/ · agents/ · skills/ · hooks/ · scripts/ · schemas/ · policies/ · templates/
```

Лицензия — Apache-2.0. Собирается из `pdlc-harness` через GitHub Action `build-gigacode-extension`.
