# PaDeLSpec Harness — расширение для GigaCode 🛡️

[![посетители](https://visitor-badge.laobi.icu/badge?page_id=avoreshin.padelspec_harness_gigacode&left_text=%D0%BF%D0%BE%D1%81%D0%B5%D1%82%D0%B8%D1%82%D0%B5%D0%BB%D0%B8&left_color=gray&right_color=1f6feb)](https://github.com/avoreshin/padelspec_harness_gigacode)
[![version](https://img.shields.io/badge/version-v0.12.0-blue?style=flat-square)](https://github.com/avoreshin/padelspec_harness_gigacode/releases)
[![license](https://img.shields.io/badge/license-Apache_2.0-green?style=flat-square)](#)

> ⚙️ Собрано автоматически из исходного репозитория [`pdlc-harness`](https://github.com/avoreshin/pdlc-harness). Не редактировать вручную — правки вносить в исходник.
> Версия сборки: **0.12.0** · источник: `5a88053`

Governance-обвязка **AI DISRUPT PDLC v3.5** как расширение [GigaCode](https://gigacode.ru) (Sber).
Превращает «модель пишет код» в управляемый процесс: команды `/pdls:*`, субагенты, скиллы,
детерминированные policy-хуки, phase-gate loop и обязательный **evidence-артефакт** на выходе.

Namespace команд — `pdls`. Бренд — **PaDeLSpec**.

**Оглавление:** [Установка](#-установка) · [Быстрый старт](#-быстрый-старт) · [Команды](#-команды-pdls) · [Control panel](#️-control-panel--pdlsharness) · [Policy-хуки](#-policy-хуки) · [Evidence bundle](#-evidence-bundle) · [Настройка](#️-настройка) · [Структура](#-структура) · [Troubleshooting](#-troubleshooting)

---

## 📦 Установка

> ⚠️ Установка **напрямую по URL не поддерживается**. Нужно сначала склонировать репозиторий, затем установить его по **локальному пути** командой `/extensions install` **изнутри GigaCode**.

**Шаг 1 — склонировать расширение (в терминале):**

```bash
git clone https://github.com/avoreshin/padelspec_harness_gigacode.git
gigacode                                   # запустить GigaCode CLI
```

**Шаг 2 — внутри сессии GigaCode установить по локальному пути:**

```
/extensions install ./padelspec_harness_gigacode
    # или абсолютный путь:
/extensions install /путь/к/padelspec_harness_gigacode

/extensions list                           # проверить → в списке padelspec-harness
```

После установки набери `/pdls:` — увидишь `/pdls:sdd-new`, `/pdls:workflow`, `/pdls:harness`, …

**Обновление:** extension-репо пере-выкладывается **force-push'ем**, поэтому `git pull` не подойдёт — в каталоге клона: `git fetch origin && git reset --hard origin/main`, затем переустановить в GigaCode (`/extensions uninstall padelspec-harness` → `/extensions install <путь>`).

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
| `/pdls:java-linter-review` | ревью Java/Spring-кода по правилам линтера — **нужен вендоринг**: сами линтеры (~115 МБ) в расширение не входят, без них команда сообщает об этом и останавливается |
| `/pdls:find-metrics` | офлайн-сканер кастомных Micrometer-метрик Java/Spring → `metrics.md` |
| `/pdls:spec-seed <путь>` | reverse: код → `capability`-спеки (`.kb/specs/*.md`), которые агент читает перед задачей; авто-декомпозиция по package, provenance на `file:line`, детекция дрейфа |
| `/pdls:test-project` | профиль тестового проекта (`docs/test-project-profile.md`): `init` · `check` · `refresh`. Раскладка, фреймворк, команды запуска и вид инвентаря шагов — из него, а не из констант команд |
| `/pdls:generate-test-cases <release>` | тест-модель по составу релиза ASFMSTD в `docs/testcases/<release>.yaml` (наружу не пишет) |
| `/pdls:generate-autotests <release>` | Cucumber-сценарии (ru) из тест-модели → инвентарь step definitions, тег `@gen-*`; offline |
| `/pdls:test-workflow <release>` | оркестратор цикла тестирования: `profile → model → autotests → review → run → export`, состояние в audit-трейле, свод по релизу на выходе. Отдельные команды при этом работают как раньше |
| `/pdls:test-run <release>` | прогон сценариев релиза по тегам `@gen-*` с разбором результата по шаблонам |
| `/pdls:review-autotests <release>` | ревью сгенерированных сценариев против тест-модели: канал проверки, полярность ожидания, именованные объекты, покрытие шагов. Read-only; `--fix` чинит механическое, не изобретая шагов |
| `/pdls:export-testcases-xml <release>` | тест-модель `docs/testcases/<release>.yaml` → XML для массовой загрузки в Zephyr Scale; `id` сценария уходит отдельным `<label>` |
| `/pdls:spec-from-commit <ref…>` | reverse: коммиты (хэш или GitHub-URL `.../commit/<sha>`) → заполненный **SDD** в `docs/sdd/`; номер задачи берётся из сообщения коммита, traceability проверяется на резолв коммитов и дрейф `anchor:` |

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
| `autotest-review-gate` | PreToolUse(Bash) | закрытие генерации и выгрузку в TMS, пока сценарии расходятся с тест-моделью |
| `evidence-bundle-enforcer` | Stop | завершение задачи без валидного evidence bundle |
| `test-loop-enforcer` | Stop | завершение сессии с незакрытым циклом тестирования без свода по релизу |
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
- **`settings.json`** (schema v3) — permission-ruleset `deny`/`ask`/`allow` (rm -rf, force-push, чтение secrets → deny; `git push`, `npm publish`, `terraform apply` → ask). GigaCode мержит его в workspace (System > Workspace > User). Правь под свой стек.
- **`gigacode-extension.json`** — манифест расширения (`name`, `version`, `contextFileName`, каталоги компонентов; `settings: []` — extension-settings пусты, permissions живут в `settings.json`).
- **`.gigacode/`** в проекте — runtime-state (`audit/`, `.cost/`, `.cache/`), создаётся автоматически, добавлен в `.gitignore`.

Диагностика конфигурации: `/pdls:harness doctor` · `/pdls:harness schemas all`.

---

## 🗂️ Структура

```
gigacode-extension.json   # манифест v3: name=padelspec-harness, contextFileName=GIGACODE.md, settings: []
settings.json             # permissions (deny/ask/allow), schema v3 — мержится в workspace
GIGACODE.md               # контекст проекта (guidance layer)
commands/pdls/*.md        # slash-команды → /pdls:<name> (namespace = поддиректория)
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
| Команды видны как `/pdls_sdd-new` (подчёркивание) или `/sdd-new` | Namespace `/pdls:` даёт **поддиректория** `commands/pdls/`, а не префикс/подчёркивание в имени файла. Обнови до v0.6.9+ и переустанови. |
| `/pdls:harness doctor` ругается на `ajv` | Запусти `/pdls:harness doctor --install` — доустановит node-пакеты в кэш. |
| `node` не найден / версия < 18 | Поставь Node ≥ 18 (`brew install node` / `nvm install --lts`). |
| Задача не завершается («evidence …») | Сработал `evidence-bundle-enforcer`. Собери bundle: `/pdls:evidence <slug>`. |

---

Лицензия — Apache-2.0. Собирается из [`pdlc-harness`](https://github.com/avoreshin/pdlc-harness) через GitHub Action `build-gigacode-extension`. История релизов — [Releases](https://github.com/avoreshin/padelspec_harness_gigacode/releases).
