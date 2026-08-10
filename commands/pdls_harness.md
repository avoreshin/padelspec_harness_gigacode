---
description: Control panel обвязки — doctor (проверка пакетов), валидация схем, включение/отключение хуков
---

Управление и диагностика harness через `.gigacode/scripts/harness.sh`. Аргументы: {{args}}

Разбери `{{args}}` и выполни соответствующую подкоманду:

- **пусто** или `doctor` → `bash .gigacode/scripts/harness.sh doctor`
  Проверяет обязательные бинарники (git/node/npm), опциональные (perl/pip3/pre-commit/rsync), node-пакеты валидатора (**ajv**, ajv-formats, js-yaml в `.gigacode/.cache/node/`) и компиляцию всех JSON-схем. Exit 0 = всё установлено.
- `doctor --install` → `bash .gigacode/scripts/harness.sh doctor --install`
  То же + one-time установка node-пакетов (ajv и др.), если их нет в кэше.
- `schemas` / `schemas all` → `bash .gigacode/scripts/harness.sh schemas all`
  Полная валидация JSON-схем и артефактов (обёртка над `validate-schemas.sh`).
- `hooks list` → `bash .gigacode/scripts/harness.sh hooks list`
  Показать активные хук-скрипты по событиям + отключённые.
- `hooks disable <name>` / `hooks enable <name>` → соответствующий вызов.
  Включает/отключает хук-скрипт в `.gigacode/settings.json` (обратимо, отключённые уезжают в ключ `$disabled_hooks`, делается бэкап `.bak`).

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

Справочник: `bash .gigacode/scripts/harness.sh --help` · плейбук по включению/отключению хуков (таблица рисков): [`docs/playbooks/hook-toggles.md`](../../docs/playbooks/hook-toggles.md).
