---
description: "🎛️ Control panel: 🩺 doctor · 📋 schemas · 🪝 hooks list/enable/disable"
---

Control panel обвязки. Аргументы: {{args}}

## Если `{{args}}` ПУСТО — ничего не запускай. Покажи пользователю это меню и спроси, какую подкоманду выполнить:

```
🎛️  /pdls:harness — control panel PaDeLSpec 🚀

  🩺  doctor [--install]      🔍 пакеты (git/node/npm, ⚡ajv…) + 🧩 компиляция схем
  📋  schemas [all]           ✅ валидация JSON-схем
  🪝  hooks list              👀 хуки (🟢 активные + 🔴 отключённые)
  ⛔  hooks disable <имя>     🚫 отключить хук (♻️ обратимо)
  🟢  hooks enable  <имя>     ✨ включить хук

💡 Примеры:  /pdls:harness doctor  🩺  ·  /pdls:harness hooks list  🪝  ·  /pdls:harness hooks disable slash-command-lint  ⛔
```

## Если `{{args}}` НЕ пусто — разбери и выполни подкоманду (через `${extensionPath}/scripts/harness.sh`):

- `doctor` → `bash ${extensionPath}/scripts/harness.sh doctor` — бинарники (git/node/npm), опциональные (perl/pip3/pre-commit/rsync), node-пакеты (**ajv**, ajv-formats, js-yaml) + компиляция схем. Exit 0 = всё ок.
- `doctor --install` → `bash ${extensionPath}/scripts/harness.sh doctor --install` — то же + one-time установка node-пакетов.
- `schemas` / `schemas all` → `bash ${extensionPath}/scripts/harness.sh schemas all` — валидация JSON-схем.
- `hooks list` → `bash ${extensionPath}/scripts/harness.sh hooks list` — активные + отключённые хуки.
- `hooks disable <name>` / `hooks enable <name>` → соответствующий вызов (обратимо, `$disabled_hooks` + бэкап `.bak`).

## Правила

1. **Сначала покажи, что собираешься запустить**, затем выполни через Bash.
2. `doctor` и `schemas` — read-only, запускай сразу.
3. `hooks enable|disable` **правит `.gigacode/settings.json` (R2, compliance-критично)**. Перед `disable` enforcement-хука:
   - предупреди пользователя, что это отключает детерминированное policy-ворото;
   - спроси подтверждение, если явного согласия ещё не было;
   - после — напомни зафиксировать причину (в evidence bundle / commit message).
4. После `doctor` кратко резюмируй: что установлено, чего не хватает и как доставить (хинты уже в выводе).

## Типичные сценарии

- «всё ли готово / установлены ли пакеты (ajv и др.)» → `doctor`
- «поставь недостающие node-пакеты» → `doctor --install`
- «проверь json-схемы» → `schemas all`
- «временно выключи хук X / включи обратно» → `hooks disable X` / `hooks enable X`

Справочник: `bash ${extensionPath}/scripts/harness.sh --help` · плейбук по включению/отключению хуков (таблица рисков): [`docs/playbooks/hook-toggles.md`](../../docs/playbooks/hook-toggles.md).
