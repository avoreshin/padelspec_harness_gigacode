---
description: Пошагово настраивает MCP-серверы Atlassian (Confluence Sigma, Confluence Delta, Jira Delta) — предустановки, выпуск четырёх токенов, установка mcp-atlassian, запись ~/.gigacode/settings.json
---

Проведи пользователя через настройку MCP-серверов Atlassian: {{args}} (опц. `--verify-only` — только проверить уже настроенное; `--tokens-only` — обновить токены, не переустанавливая пакеты).

**Тип задачи:** настройка рабочего места, **R1** — вне PDLC-loop'а, phase-gate не выполняется. Репозиторий не меняется: всё пишется в домашний каталог пользователя.

## Процесс

Выполни skill `mcp-atlassian-setup`. Оркестратор, который скилл называет `<SETUP>`, лежит здесь:

```
${extensionPath}/scripts/setup-mcp-atlassian.sh
```

Шаги идут по одному, каждый ждёт ответа пользователя:

0. `check` — осмотр машины, ничего не меняет. `FAIL` — останов с объяснением.
1. Предустановки из SUS (Node.js, GigaCode Desktop, Python, Pip) + для SberOS перезагрузка и заявка в «Друге».
2. Четыре API-токена, по одному, каждый со ссылкой на страницу выпуска.
3. Адрес почты sigma.
4. Путь к `python.exe` — только Windows и только если venv ещё нет.
5. Сводка изменений и явное подтверждение.
6. `apply` — установка.
7. `verify` — проверка, что серверы действительно запускаются.

С `--verify-only` выполняется только шаг 7. С `--tokens-only` — шаги 0, 2, 3, 5 и `apply --tokens-only`: переписывается только `settings.json`, пакеты и `~/.npmrc` не трогаются, токен SberOSC не нужен.

Полные тексты шагов, обращение с токенами и разбор ошибок — в самом skill'е (`${extensionPath}/skills/mcp-atlassian-setup/SKILL.md`).

## Что меняется на машине

| Что | Где |
|---|---|
| `mcp-atlassian`, `requests`, `redis` | `~/.venv`, на SberOS `<work_dir>/.venv` |
| Конфиг npm | `~/.npmrc` — **перезаписывается целиком** |
| Серверы `atlassian`, `delta-confluence` | `~/.gigacode/settings.json` — дописываются, чужие серверы сохраняются |

## Гарантии

- `check` не меняет ничего — его можно запускать сколько угодно.
- Файл с токенами (`~/.giga_sberosc`) создаётся с правами `600` и удаляется при любом исходе, включая падение `pip`.
- `settings.json` не редактируется текстом: слияние делает скрипт, поэтому уже настроенные MCP-серверы не теряются.
- Без явного подтверждения на шаге 5 `apply` не запускается.

## Output (в чат)

```
✅ MCP Atlassian настроен

Серверы:  atlassian (Confluence Sigma + Jira Delta) · delta-confluence (Confluence Delta)
Конфиг:   ~/.gigacode/settings.json
Проверка: OK <N> · WARN <M> · FAIL 0

Перезапустите GigaCode CLI — серверы читаются при старте.
```

**Примечание:** команда не является фазой loop'а — phase-gate transition не выполняется.
