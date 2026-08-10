# PaDeLSpec Harness — расширение для GigaCode 🛡️

> ⚙️ Собрано автоматически из исходного репозитория [`pdlc-harness`](https://github.com/avoreshin/pdlc-harness). Не редактировать вручную — правки вносить в исходник.
> Версия сборки: **0.6.5** · источник: `5c0e43f`

Governance-обвязка **AI DISRUPT PDLC v3.5** как расширение [GigaCode](https://gigacode.ru) (Sber).
Превращает «модель пишет код» в управляемый процесс: команды `/pdls:*`, субагенты, скиллы,
детерминированные policy-хуки, phase-gate loop и обязательный **evidence-артефакт** на выходе.

Namespace команд — `pdls`. Бренд — **PaDeLSpec**.

**Оглавление:** [Установка](#-установка) · [Быстрый старт](#-быстрый-старт) · [Команды](#-команды-pdls) · [Control panel](#️-control-panel--pdlsharness) · [Policy-хуки](#-policy-хуки) · [Evidence bundle](#-evidence-bundle) · [Настройка](#️-настройка) · [Структура](#-структура) · [Troubleshooting](#-troubleshooting)

---

## 📦 Установка

```bash
# из GitHub (обычный сценарий):
gigacode extensions install https://github.com/avoreshin/padelspec_harness_gigacode

# или локально (dev, symlink — правки видны сразу):
gigacode extensions link /путь/к/padelspec-harness-gigacode

# проверить, что команды подхватились:
gigacode extensions list          # → в списке padelspec-harness
# в сессии GigaCode: набери /pdls: и увидишь /pdls:sdd-new, /pdls:workflow, …
```

**Требования:** `bash`, `git`, `node ≥ 18` (JSON-валидатор `ajv` доустанавливается автоматически при первом запуске в кэш `.gigacode/.cache/node/`).
Проверить окружение одной командой: **`/pdls:harness doctor`** 🩺 (см. [Control panel](#️-control-panel--pdlsharness)).

---

## 🚀 Быстрый старт

Инициализировать harness в своём проекте и пройти задачу целиком:

```
/pdls:init-project           # разложить .gigacode/ в текущем репо (один раз)
/pdls:harness doctor         # 🩺 проверить, что всё на месте (node, ajv, схемы)

/pdls:workflow add-search    # оркестратор: проведёт задачу через все фазы
```

Или пофазно, вручную:

```
/pdls:sdd-new add-search     # 1. спека (SDD) — задаст 3 вопроса
/pdls:plan   add-search      # 2. план реализации
/pdls:test   add-search      # 3. failing-тесты (TDD)
/pdls:implement add-search   # 4. код, пока тесты не зелёные
/pdls:review add-search      # 5. ревью против SDD
/pdls:evidence add-search    # 6. evidence bundle — без него задача не закрыта
```

Прервались? **`/pdls:continue add-search`** подхватит с последней завершённой фазы.

---

## 🧭 Команды `/pdls:*`

Каждая задача проходит фазы (§2.13 PDLC), каждая фаза — команда:

| Шаг | Команда | Что делает |
|---|---|---|
| 1. Спека | `/pdls:sdd-new <slug>` | Software Design Document; 3 вопроса (risk class, acceptance criteria, reviewer) |
| 2. План | `/pdls:plan <slug>` | implementation plan (read-only субагенты explore + plan) |
| 3. Тесты | `/pdls:test <slug>` | failing tests из AC (TDD; трогать `src/` запрещено) |
| 4. Код | `/pdls:implement <slug>` | минимальный код, пока тесты не зелёные (тесты неприкосновенны) |
| 5. Ревью | `/pdls:review <slug>` | сверка с SDD/AC (review + security-субагент для R3+) |
| 6. Evidence | `/pdls:evidence <slug>` | evidence bundle — задача не закрыта без него |

**Оркестратор:** `/pdls:workflow <slug>` — проводит через все фазы · **Возобновить:** `/pdls:continue <slug>`.

**Утилиты:**

| Команда | Назначение |
|---|---|
| `/pdls:init-project` | разложить harness (`.gigacode/`) в текущем репозитории |
| `/pdls:harness` | 🎛️ control panel: doctor · schemas · hooks (см. ниже) |
| `/pdls:risk-classify` | определить risk class (R0–R5) для задачи |
| `/pdls:metrics` | DORA-метрики из audit-трейла |
| `/pdls:squash` | подготовить чистую историю коммитов к PR |
| `/pdls:java-linter-review` | ревью Java/Spring-кода по правилам линтера |

---

## 🎛️ Control panel — `/pdls:harness`

Единая точка диагностики и управления обвязкой. Без аргументов показывает меню:

```
🎛️  /harness — control panel PaDeLSpec 🚀

  🩺  doctor [--install]      🔍 пакеты (git/node/npm, ⚡ajv…) + 🧩 компиляция схем
  📋  schemas [all]           ✅ валидация JSON-схем
  🪝  hooks list              👀 хуки (🟢 активные + 🔴 отключённые)
  ⛔  hooks disable <имя>     🚫 отключить хук (♻️ обратимо)
  🟢  hooks enable  <имя>     ✨ включить хук
```

| Подкоманда | Что делает |
|---|---|
| `/pdls:harness doctor` | 🩺 проверяет бинарники (git/node/npm), node-пакеты (**ajv**, ajv-formats, js-yaml) и компиляцию всех схем |
| `/pdls:harness doctor --install` | то же + one-time установка node-пакетов в кэш |
| `/pdls:harness schemas all` | 📋 валидирует все JSON-схемы + negative-фикстуры |
| `/pdls:harness hooks list` | 🪝 показывает активные (по событиям) и отключённые хуки |
| `/pdls:harness hooks disable <name>` | ⛔ временно отключает хук (обратимо, с бэкапом) |
| `/pdls:harness hooks enable <name>` | 🟢 включает хук обратно |

> ⚠️ `hooks disable` enforcement-хука отключает детерминированное policy-ворото (**R2, compliance-риск**). Причину отключения зафиксируй в evidence bundle / commit message.

---

## 🪝 Policy-хуки

Хуки — это **детерминированные gate'ы** (exit-code, не «просьба к модели»). Срабатывают на события GigaCode и блокируют нарушение до его совершения. Wiring — в `hooks/hooks.json`.

| Хук | Событие | Блокирует |
|---|---|---|
| `destructive-command-blocker` | PreToolUse(Bash) | `rm -rf`, `git push --force`, и пр. деструктив |
| `pii-boundary-check` | PreToolUse | чтение/вывод secrets (`.env`, `*.pem`, credentials) |
| `commit-message-format` | PreToolUse(Bash git) | коммиты не по Conventional Commits |
| `branch-naming-gate` | PreToolUse(Bash git) | ветки не по конвенции именования |
| `test-files-protector` | PreToolUse(Edit) | правку тестов на фазе Implement (меняет AC) |
| `sdd-schema-gate` | PreToolUse | SDD, не проходящий схему |
| `ai-code-quality-gate` | PostToolUse | код ниже quality-порога |
| `evidence-bundle-enforcer` | Stop | завершение задачи без валидного evidence bundle |
| `jsonl-audit-sink` | (все) | — пишет audit-трейл в `.gigacode/audit/` |

Полный список — `/pdls:harness hooks list`. Включение/отключение — там же.

---

## 📑 Evidence bundle

Любая агентная задача закрывается **только** после сборки evidence bundle (`/pdls:evidence`). Это машинно-проверяемый артефакт с:

- diff summary (изменённые файлы, +/− строк);
- выполненными командами (test / lint) и их результатами (passed/failed/skipped);
- unresolved assumptions / open risks;
- risk class задачи и ссылкой на SDD + acceptance criteria.

`Stop`-хук `evidence-bundle-enforcer` валидирует файл по схеме `schemas/evidence-bundle.schema.json` и **блокирует** завершение сессии, если bundle отсутствует или лжёт о scope (сверяется с `git`).

---

## ⚙️ Настройка

- **`GIGACODE.md`** — контекст проекта для агента: стек, конвенции, риск-классы R0–R5, что делать/не делать. **Главный файл для кастомизации под свой репозиторий.**
- **`hooks/hooks.json`** — wiring policy-хуков по событиям. Включать/отключать хуки удобнее через `/pdls:harness hooks disable|enable <name>` (правит конфиг + делает бэкап).
- **`policies/risk-ladder.yaml`** — лимиты и требования по классам R0–R5 (autonomy, review, token-budget).
- **`gigacode-extension.json`** — манифест расширения (`name`, `version`, `contextFileName`, каталоги компонентов). Enforcement живёт в самих хуках, не в манифесте.
- **`.gigacode/`** в проекте — runtime-state (`audit/`, `.cost/`, `.cache/`), создаётся автоматически, добавлен в `.gitignore`.

Диагностика конфигурации: `/pdls:harness doctor` · `/pdls:harness schemas all`.

---

## 🗂️ Структура

```
gigacode-extension.json   # манифест v3: name=padelspec-harness, contextFileName=GIGACODE.md, settings: []
GIGACODE.md               # контекст проекта (guidance layer)
commands/pdls_*.md        # slash-команды → /pdls:<name>
agents/                   # определения субагентов (explore, plan, test, coding, review, security)
skills/                   # скиллы (humanizer и др.)
hooks/                    # policy-хуки (*.sh) + hooks.json (event-wiring)
scripts/                  # bash/node-утилиты (harness.sh, validate-schemas.sh, …)
schemas/                  # JSON Schema артефактов (evidence, sdd, dora, …)
policies/                 # risk-ladder.yaml + policy-as-code
templates/                # шаблоны SDD / ADR / evidence
```

---

## 🩹 Troubleshooting

| Симптом | Причина / решение |
|---|---|
| `settings.filter is not a function` при install | Старая сборка (`settings` был объектом). Обнови до v0.6.1+ — теперь `settings: []`. |
| Команды видны как `/sdd-new`, а не `/pdls:sdd-new` | Namespace даёт префикс файлов `pdls_*.md`. Переустанови из свежего релиза. |
| `/pdls:harness doctor` ругается на `ajv` | Запусти `/pdls:harness doctor --install` — доустановит node-пакеты в кэш. |
| `node` не найден / версия < 18 | Поставь Node ≥ 18 (`brew install node` / `nvm install --lts`). |
| Задача не завершается («evidence …») | Сработал `evidence-bundle-enforcer`. Собери bundle: `/pdls:evidence <slug>`. |

---

Лицензия — Apache-2.0. Собирается из [`pdlc-harness`](https://github.com/avoreshin/pdlc-harness) через GitHub Action `build-gigacode-extension`. История релизов — [Releases](https://github.com/avoreshin/padelspec_harness_gigacode/releases).
