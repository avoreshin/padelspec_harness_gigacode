---
description: Развернуть pdlc-harness в текущий репозиторий за один шаг
---

Установи и настрой pdlc-harness в **текущий рабочий каталог**.

Контекст: {{args}}

## Процесс

**Шаг 1 — Спроси у пользователя четыре вещи** (используй `AskUserQuestion`):

1. **Stack** — основной язык/runtime (Node 22, Python 3.12, Go 1.22, Java 21, etc.)
2. **Framework / архитектура** — Express, FastAPI, Django, Spring Boot, monolith, microservices...
3. **R3+ домены** — какие части кодовой базы трогают auth / payments / PII / infra. Если нет — пустая строка.
4. **Owner** — команда или роль, ответственная за этот репо.

Если пользователь сказал «дефолты» или дал контекст в `{{args}}` — не задавай лишних вопросов, восстанови ответы из контекста.

**Шаг 2 — Запусти инсталлятор:**

```bash
bash .gigacode/scripts/init-project.sh \
  --stack "<answer 1>" \
  --framework "<answer 2>" \
  --r3-domains "<answer 3>" \
  --owner "<answer 4>"
```

(Если `.gigacode/scripts/init-project.sh` ещё не существует — пользователь запускает команду на новом репо. Тогда нужно знать путь к checkout'у pdlc-harness и вызвать оттуда:)

```bash
PDLC_HARNESS_SRC=/path/to/pdlc-harness \
bash /path/to/pdlc-harness/.gigacode/scripts/init-project.sh --target "$PWD" \
  --stack "..." --framework "..." --r3-domains "..." --owner "..."
```

**Шаг 3 — Проверь отчёт скрипта.** Скрипт печатает summary: сколько файлов скопировано, какие плейсхолдеры заполнены, прошёл ли smoke-test destructive-command-blocker. Если smoke-test FAIL — это критично, harness не работает, разбираться сразу.

**Шаг 4 — Покажи пользователю next steps**:

```
✅ pdlc-harness установлен.

Что осталось вручную:
1. Открыть .gigacode/GIGACODE.md и заполнить оставшиеся <…> плейсхолдеры
   (архитектура, conventions кода, naming, тесты).
2. Отредактировать docs/adr/0001-pilot-scope.md под реальный пилот.
3. Когда готов — /pdls:sdd-new <первая фича> и пойдёт обычный workflow.
```

## Гарантии

- Скрипт **не перезаписывает** существующий `.gigacode/` без `--force`. Если уже есть — переименовывает в `.gigacode.bak`.
- Хуки делаются исполняемыми автоматически.
- Runtime-артефакты (`audit/`, `settings.local.json`, `evidence-bundle*.json`) не копируются — они локальные.
- `.gitignore` дополняется, не перезаписывается.

## Когда НЕ использовать

- Если уже работаете в pdlc-harness как в шаблоне — не запускайте на нём самом.
- Если в репо уже есть кастомизированный `.gigacode/` с критичными правками — сначала `git commit`, потом думайте про migration, не про `--force`.
