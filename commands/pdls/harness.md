---
description: "🎛️ Control panel: 🩺 doctor · 📋 schemas · 🪝 hooks (чекбоксы вкл/выкл) · 🧪 test extension"
---

Control panel обвязки. Аргументы: {{args}}

## Если `{{args}}` ПУСТО — ничего не запускай. Покажи это меню и спроси, что выполнить:

```
🎛️  /pdls:harness — control panel PaDeLSpec 🚀

  🩺  doctor [--install]      🔍 пакеты (git/node/npm, ⚡ajv…) + 🧩 компиляция схем
  📋  schemas [all]           ✅ валидация JSON-схем
  🪝  hooks                   ☑️ чекбоксы: вкл/выкл хуки одним списком
  🪝  hooks list              👀 просто показать (🟢 активные + 🔴 отключённые)
  ⛔  hooks disable <имя>     🚫 отключить хук напрямую (♻️ обратимо)
  🟢  hooks enable  <имя>     ✨ включить хук напрямую
  🧪  test [EXT_DIR]          🩻 hook-doctor: проверить хуки установленного расширения

💡 /pdls:harness hooks  ☑️  ·  /pdls:harness test  🧪  ·  /pdls:harness doctor  🩺

──────────────────────────────────────────────────────────
🧭 Остальные команды обвязки (полный workflow — /pdls:workflow):

  📐 /pdls:sdd-new       создать SDD-спеку задачи
  🧠 /pdls:risk-classify определить risk class R0–R5
  🗺️ /pdls:plan          implementation plan из SDD (read-only)
  🧪 /pdls:test          failing-тесты из acceptance criteria (TDD)
  🔨 /pdls:implement     минимальный код под тесты
  🔎 /pdls:review        сверка кода с SDD
  📦 /pdls:evidence      собрать evidence bundle (обязательный финал)
  ▶️ /pdls:continue      возобновить задачу из audit-trail
  📊 /pdls:metrics       Autonomy/Quality/Cost/Trust
  🔬 /pdls:find-metrics  Micrometer dev-метрики → metrics.md
  ☕ /pdls:java-linter-review  офлайн-анализ Java на code smells
  🧰 /pdls:init-project  one-command setup обвязки в новом репо
  🩻 /pdls:harness-report  снимок состояния обвязки одним файлом

🧪 Цикл тестирования (полный прогон — /pdls:test-workflow):

  🗂️ /pdls:test-project      профиль тестового проекта: где тесты, чем запускаются
  🧪 /pdls:generate-test-cases   состав релиза ASFMSTD → docs/testcases/<release>.yaml
  🥒 /pdls:generate-autotests    тест-модель релиза → Cucumber-сценарии
  🔎 /pdls:review-autotests      сверка сценариев с тест-моделью (--fix чинит механическое)
  🚦 /pdls:release-readiness     барьер: закрыта ли разработка по каждой story
  ▶️ /pdls:test-run              прогон по тегам @gen-* и разбор падений
  📤 /pdls:export-testcases-xml  XML для импорта в Zephyr
```

## Если `{{args}}` НЕ пусто — разбери и выполни подкоманду:

- `doctor` → `bash ${extensionPath}/scripts/harness.sh doctor` — бинарники + node-пакеты (**ajv**…) + компиляция схем. Read-only, запускай сразу.
- `doctor --install` → `bash ${extensionPath}/scripts/harness.sh doctor --install` — то же + one-time установка node-пакетов.
- `schemas` / `schemas all` → `bash ${extensionPath}/scripts/harness.sh schemas all` — валидация JSON-схем. Read-only.
- `test` / `test <EXT_DIR>` → `bash ${extensionPath}/scripts/harness.sh test <EXT_DIR>` — hook-doctor: см. раздел **🧪 test** ниже.
- `hooks` (без имени) → **интерактивные чекбоксы**: см. раздел **☑️ hooks (чекбоксы)** ниже.
- `hooks list` → `bash ${extensionPath}/scripts/harness.sh hooks list` — человекочитаемый список.
- `hooks disable <name>` / `hooks enable <name>` → прямой вызов (обратимо, `$disabled_hooks` + бэкап `.bak`).

---

## ☑️ hooks (чекбоксы) — когда пользователь набрал `/pdls:harness hooks` без имени

Цель: дать вкл/выкл через галочки, а не запоминать имена.

1. Считай текущее состояние — машиночитаемо:
   `bash ${extensionPath}/scripts/harness.sh hooks status`
   Формат: `STATE<TAB>NAME<TAB>EVENTS` (STATE = `enabled` | `disabled`).

2. Построй чекбокс-пикер через **`AskUserQuestion` с `multiSelect: true`**. Ограничения инструмента: ≤ 4 опции на вопрос, ≤ 4 вопросов. Хуков больше 4 — **разбей на несколько вопросов группами по 4** (по порядку из вывода).
   - Семантика без предвыбора: спрашивай **отдельно про включённые и про отключённые**, чтобы «галочка = изменить состояние»:
     - Вопрос(ы) **«Какие хуки ВЫКЛЮЧИТЬ?»** — опции только из `enabled` (отмеченное → disable).
     - Вопрос **«Какие хуки ВКЛЮЧИТЬ?»** — опции только из `disabled` (отмеченное → enable). Пропусти, если отключённых нет.
   - В `description` каждой опции покажи события (`EVENTS`) и пометку риска (см. таблицу рисков в плейбуке).
   - Если хуков так много, что не влезают в 4×4 — обработай сначала enforcement-критичные (destructive/pii/evidence/sdd-schema/commit/branch/iteration-cap), остальное добери вторым проходом или предложи ввести имена.

3. Примени выбор:
   - для каждого отмеченного к выключению → `bash ${extensionPath}/scripts/harness.sh hooks disable <name>`
   - для каждого отмеченного к включению → `bash ${extensionPath}/scripts/harness.sh hooks enable <name>`
   Запускай по одному вызову на хук; после — `hooks status` ещё раз и покажи итог.

4. **Guardrail (R2, compliance-критично).** Отключение enforcement-хука правит `.gigacode/settings.json`:
   - предупреди, что снимаешь детерминированное policy-ворото;
   - если явного согласия ещё не было — подтверди отдельно перед disable;
   - напомни зафиксировать причину (evidence bundle / commit message).

---

## 🧪 test — проверить хуки установленного расширения

Пользователь жалуется, что «хуки не работают после установки `padelspec_harness_gigacode`» — это про это.

- `test` без аргумента → `bash ${extensionPath}/scripts/harness.sh test` — автоопределит каталог расширения (сам extension, типовые пути установки GigaCode, либо `.gigacode/` текущего репо).
- `test <EXT_DIR>` → проверить конкретную установку, напр. `~/.gigacode/extensions/padelspec-harness`.

Скрипт (`verify-gigacode-hooks.sh`) по каждому wired-хуку проверяет: **окружение** (bash/jq/node — без `jq` хуки молча падают), **wiring** (какой хук на какое событие, оба формата: `settings.hooks` и `hooks.json`), **файл** (существует, `+x`, без CRLF, шебанг), **синтаксис** (`bash -n`), **запуск** на репрезентативном stdin и **блокировку** заведомо плохого ввода 4 guard-хуками. Итог: `PASS/WARN/FAIL` + подсказки по починке.

После прогона резюмируй: если `FAIL` — назови первопричину (чаще всего нет `jq` в PATH GigaCode, снят `+x`, CRLF или пустой wiring).

---

## Правила

1. **Сначала покажи, что запускаешь**, затем выполни через Bash.
2. `doctor`, `schemas`, `test`, `hooks list|status` — read-only, запускай сразу.
3. `hooks enable|disable` — R2, правит `settings.json` (см. Guardrail выше).
4. После `doctor` кратко резюмируй: что установлено, чего не хватает и как доставить.

Справочник: `bash ${extensionPath}/scripts/harness.sh --help` · плейбук вкл/выкл хуков (таблица рисков): [`docs/playbooks/hook-toggles.md`](../../docs/playbooks/hook-toggles.md).
