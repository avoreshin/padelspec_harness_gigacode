# Changelog — PaDeLSpec Harness (GigaCode extension)

Версия расширения — v0.8.1 (см. `gigacode-extension.json` → `version` и файл `VERSION`).
Собрано из pdlc-harness. Релизы плагина: https://github.com/avoreshin/padelspec_harness_gigacode/releases

---

# Changelog

Все значимые изменения pdlc-harness фиксируются в этом файле.

Формат: [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).
Версионирование: [Semantic Versioning](https://semver.org/lang/ru/) (pre-1.0 → minor = добавление, patch = fix).

Каждая release-версия живёт в собственной ветке `release/vX.Y.Z` (snapshot для hotfix patch'ей) и имеет immutable tag `vX.Y.Z`.

---

## [Unreleased]

### Fixed

- **CHANGELOG расширения был заглушкой-указателем, а не реальными записями.** `build-gigacode-extension.sh` генерировал `CHANGELOG.md` расширения через heredoc из трёх строк («версия v…, см. releases / source changelog»), поэтому в `padelspec_harness_gigacode` не было истории изменений. Теперь build кладёт короткий заголовок + **полный source-CHANGELOG** (`cat CHANGELOG.md`) → в расширении реальные секции всех версий. Проверено: сборка v0.8.1 содержит 27 версий-секций.

## [v0.8.1] - 2026-08-20

Две команды для тестировщика проекта `orchestrator-autotest`: от состава релиза в Jira до готовых Cucumber-сценариев. Специфика проекта (Jira Delta, Zephyr TAF `projectId=66704`, link type «Состав релиза» `id=11400`, русский Gherkin, таблица step definitions) зашита в skills осознанно — так же, как `/find-metrics` привязан к Java/Spring/Micrometer.

### Added

- **`/generate-test-cases <release> [--apply]`** + skill `tc-from-release` — читает состав релиза UPG через link type `11400`, отбирает Story/Task, определяет компонент по словам-триггерам (8 компонентов) и стенды, генерирует тест-кейсы и создаёт их в Zephyr с привязкой к story. [`feat(commands): add /generate-test-cases and /generate-autotests (v0.8.1)`]

  **Запись в Jira идёт в два прохода через файл.** Проход 1 кладёт сценарии в `docs/testcases/<release>.yaml` и останавливается, ничего не создав. Человек читает и при необходимости правит файл. Проход 2 (`--apply`) создаёт TC, читая **этот файл**, а не генерируя заново.

  Так сделано потому, что Zephyr — общий трекер, который видит вся команда, а откат создания сорока с лишним TC делается руками. Альтернатива с подтверждением в чате была отвергнута: там человек утверждает один список, а создаётся сгенерированный повторно — похожий, но не гарантированно тот же. Файл снимает расхождение и вдобавок позволяет править сценарии до применения.

  Побочный выигрыш — идемпотентность без внешних запросов. Проход 2 дописывает в файл `status: applied` и `key: TAF-Txxxx` в каждый блок; повторный `--apply` отказывается работать и печатает уже созданные ключи. Благодаря этому `zephyr_search_test_cases` (у которого подтверждён баг с полем `components`) перестал быть несущим — он больше не отвечает на вопрос «создавали ли мы эти TC».

- **`/generate-autotests <tc-list>`** + skill `autotest-generator` — читает тест-кейсы из Zephyr, конвертирует Test Script в существующие step definitions, группирует сценарии по компоненту в `core/` или `debug/` и проставляет тег `@TAF-Txxxx` как трассировку «автотест ↔ тест-кейс».

  Ненайденный шаг **не выдумывается**. Формулировка предупреждения — «не найден в локальных step definitions, возможно из `fraud-plugin v3.5.15`, проверь до добавления», а не «шага нет»: база Cucumber-шагов приходит из внешнего плагина, и обратная формулировка провоцировала бы написать дубль поверх него.

- **`--tc=TAF-T1,TAF-T2` в `/test`** — опциональный вход: acceptance criteria берутся из тест-кейсов Zephyr вместо AC из SDD. Без флага поведение команды не меняется.

- **Preflight в обеих новых командах.** `/generate-test-cases` проверяет доступность Jira MCP живым вызовом `get_project("TAF")` и наличие `docs/harness/modules/`; `/generate-autotests` — `pom.xml`, step definitions, каталог feature-файлов и живой `zephyr_get_test_case()`. Проверка не прошла — команда останавливается и перечисляет всё недостающее сразу, не пытаясь работать в деградированном режиме.

  Проверка MCP сделана живым вызовом, а не поиском конфига на диске, намеренно: конфигурация может присутствовать и при этом не работать — протухший токен, недоступный хост, отключённый VPN.

### Why

Тест-кейсы по составу релиза заводились вручную, а автотесты писались по ним отдельно, второй раз перечитывая те же story. Обе операции механические, но ошибка в них дорогая: TC живут в общем трекере, а автотесты — в общей кодовой базе.

Разрыв между командами оставлен намеренно: человек смотрит на тест-кейсы до того, как они попадут в Jira, и до того, как из них поедет код.

### Известные ограничения

- `PreconditionsStepDefinitions` и `UtilStepDefinitions` пока недоступны генератору — их сигнатуры не перенесены в таблицу mapping. Сценарии, которым нужны подготовительные или служебные шаги, уходят в блок «требуется добавить step definitions».
- Каталог feature-файлов определяется поиском (`src/main/resources/features/` → `src/test/resources/features/` → `features/`), а не константой: step definitions в этом проекте лежат под `src/main/java/`, поэтому раскладка feature-файлов заранее не известна.
- Генерация как таковая LLM-зависима и smoke-уровнем не покрывается — см. `tests/README.md`, раздел «Что НЕ покрыто».

## [v0.8.0] - 2026-08-14

Frontend-задачам не хватало UI-специфики в SDD — добавлен отдельный шаблон. Плюс закрыт CRLF-дефект, из-за которого сборка расширения падала и релиз не публиковался.

### Added

- **`templates/SDD-frontend-template.md`** — SDD-шаблон для frontend/UI-задач. Сохраняет обязательную нумерацию секций (`## 1/2/4/5/8/13`) для `sdd-schema-gate`, но перепрофилирует остальные под UI: **§6 Component/UI contract** (`@Input`/`@Output`, CD-стратегия, RxJS-гигиена, standalone/signals, тестирование через CDK harnesses), **§7 UI/UX** (layout, матрица состояний empty/loading/error/success, взаимодействия+клавиатура, адаптивность, UI-kit-agnostic токены — Material/Taiga/Tailwind, a11y WCAG 2.2 AA, i18n, темизация light/dark), фронтенд-DoD и таблица skills по фазам. `/sdd-new` выбирает его для frontend-задач. Проверено на двух реальных Angular-проектах (легаси Material R1 и Angular 21 + Taiga UI R2).

### Fixed

- **`scripts/build-gigacode-extension.sh` уехал в `main` с CRLF-концами строк** (185 строк) — `bash` падал на первой же строке с `$'\r': command not found` / `set: pipefail: invalid option name`, поэтому workflow `build-gigacode-extension` при мерже v0.7.3 упал и расширение НЕ опубликовалось (застряло на 0.7.2, без fail-closed-jq фиксов). Ирония: сам скрипт, который в v0.7.3 нормализует `.sh` в сборке, приехал с Windows с CRLF. Нормализован в LF; добавлен `.gitattributes` (`*.sh text eol=lf`), чтобы `.sh` больше не приезжали с CRLF. Проверено: сборка отрабатывает под `LC_ALL=C`, даёт v0.7.3, хук-доктор по сборке — 73 PASS / 0 FAIL.

## [v0.7.3] - 2026-08-12

Enforcement-слой отказывал молча. Найдено e2e-прогоном настоящей агентной сессии против обвязки в одноразовом репозитории — юнит-уровень `tests/smoke/` это поймать не мог в принципе, потому что там хуки вызываются напрямую и их exit-код сравнивается с ожидаемым, а не интерпретируется так, как его интерпретирует GigaCode.

### Fixed

- **11 из 16 хуков молча переставали применять политику при отсутствии `jq` (fail-open).** Разбор события держится на `jq`; без него хук падал на первом же вызове с **exit 127**, а блокировкой GigaCode считает **только exit 2** — любой другой код означает «хук не сработал, продолжаем». При этом `settings.json` продолжал показывать хуки включёнными, а `harness.sh doctor` не проверял `jq` вовсе (в `REQ_BINS` были только `git`/`node`/`npm`). Для compliance-слоя это худший режим отказа: защита выглядит включённой, но не применяется.

  Подтверждено e2e: на машине без `jq` агент по задаче «закоммить с сообщением `fixed stuff`» спокойно создавал коммит — `commit-message-format.sh` не срабатывал. После фикса тот же прогон блокируется на входе, репозиторий остаётся нетронутым.

  Добавлен `hooks/lib/require-jq.sh` — общий fail-closed гейт: нет парсера → `{"decision":"block"}` + exit 2 с инструкцией, как поставить `jq`. Подключён в 12 хуков (напрямую или через `lib/common.sh`). Разделение поведения по событиям получается само собой, без ветвления: на PreToolUse/Stop exit 2 блокирует вызов, на PostToolUse инструмент уже отработал и Claude просто получает причину в stderr.

  `sdd-schema-gate.sh` намеренно оставлен без гейта: у него есть рабочий grep-fallback, он деградирует корректно. Обратный smoke-кейс (S12.13) фиксирует это, чтобы гейт не подключили туда по ошибке.

- **Неполная установка обвязки тоже вела к fail-open.** Если каталога `hooks/lib/` нет (хук скопирован без него — так делал и `setup_temp_repo` в `tests/smoke/hooks-core.sh`), `source` падал, и под `set -e` хук завершался с **exit 1** — снова «не сработал, продолжаем». Все подключения переведены на `source … || exit 2`.

- **`$(dirname "$0")` в подключении библиотек — внешняя зависимость там, где её быть не должно.** В урезанном окружении без `dirname` гейт молча не подгружался бы, то есть отказ ровно того вида, который он закрывает. Заменено на раскрытие bash `${BASH_SOURCE[0]%/*}` — без внешних команд.

- **`harness.sh doctor`:** `jq` переведён в `REQ_BINS` с install-подсказкой. Доктор обязан краснеть на машине, где enforcement применить нельзя.

- **`verify-gigacode-hooks.sh` рапортовал ложное «wiring не найден» для любой корректной сборки.** В манифесте v3 ключ `hooks` — это строка-путь (`"hooks/"`), а не wiring-словарь; `emit()` вызывал на ней `.items()` и падал с `AttributeError` на первом же источнике, не доходя до `hooks/hooks.json`, где лежат настоящие привязки. `2>/dev/null` прятал traceback, поэтому наружу шло «Без wiring GigaCode не знает, когда вызывать хуки — они не сработают никогда». Главная проверка доктора была сломана и пугала ложной тревогой. Добавлены проверки типов и изоляция источников друг от друга. На собранном расширении: было `FAIL — wiring не найден`, стало `PASS — найдено wired-привязок: 20`.

- **Сборка расширения падала на Windows** (`scripts/build-gigacode-extension.sh`) — тот же cp1251, что в v0.7.2, но в корневом `scripts/`, который тогда не попал в скоуп правки. В CI (Linux/UTF-8) не воспроизводится, поэтому не всплывало.

- **Расширение, собранное на Windows, уезжало с CRLF в хуках** — `bash` на таком файле падает с `$'\r': command not found`, то есть установка выглядела успешной, а хуки не работали. Две причины: `cp -R` копирует рабочую копию как есть (`core.autocrlf=true`), а Python в текстовом режиме на Windows пишет CRLF. Все записи в сборке переведены на явный `newline="\n"`, плюс финальная нормализация `.sh`. Публикуемые сборки не были затронуты (workflow идёт на `ubuntu-latest`), но локальная сборка молча давала битое расширение. Прогон хук-доктора по сборке: было `PASS 55 · FAIL 17`, стало `PASS 72 · FAIL 0`.

- **Текст блокировки `require-jq.sh` ссылался на путь `.gigacode/scripts/harness.sh`,** которого в GigaCode-установке нет (там `${extensionPath}/scripts/`). Переписан на команду — `/harness doctor`, в GigaCode `/pdls:harness doctor`.

### Added

- **Suite 12** в `tests/smoke/hooks-extended.sh` — 13 кейсов на контракт fail-closed. `PATH` подменяется на пустой каталог (окружение вообще без внешних команд), каждый jq-зависимый хук обязан отдать exit 2. Именно поэтому гейт и подключается через `${BASH_SOURCE[0]%/*}`. Плюс обратный кейс на `sdd-schema-gate`.
- **Suite 3** в `tests/smoke/scripts.sh` + фикстура `tests/fixtures/gigacode-ext/` — регрессия на разбор wiring: минимальная сборка расширения, где `hooks` в манифесте строка, а привязки лежат в `hooks/hooks.json`. Проверено, что кейс красный на коде до фикса. Итого smoke: 87 кейсов (33 + 38 + 16).

### Известные ограничения

- **INV-1:** на машине без `jq` обвязка теперь отказывает **на первом же хуке** (`prompt-validator` на UserPromptSubmit), то есть сессия не начнётся, пока `jq` не установлен. Это осознанный размен: громкий отказ с инструкцией вместо тихой неработающей защиты. Обход, если он нужен осознанно, — `harness.sh hooks disable <name>`, что фиксирует решение явно.

## [v0.7.2] - 2026-08-12

Python-обвязка харнесса брала кодировку из локали хоста. На Windows с русской локалью (cp1251 — дефолт «из коробки») это ломало команды и один Stop-хук. Файлы харнесса всегда UTF-8, поэтому кодировка теперь задаётся явно, а не наследуется от машины.

### Fixed

- **`/harness hooks list` падал на Windows с не-UTF-8 локалью.** `hooks_list` печатает заголовок с эмодзи 🪝 (U+1FA9D) из python3-heredoc; при `sys.stdout.encoding = cp1251` это `UnicodeEncodeError` и exit 1 — команда не работала вообще. Соседний `hooks status` выживал только потому, что не печатает не-ASCII. Все три python3-вызова в `harness.sh` переведены на обёртку `py()` (UTF-8 Mode, PEP 540), чтение и запись `settings.json` получили явный `encoding='utf-8'`.
- **`evidence-bundle-enforcer.sh` мог заблокировать закрытие сессии на валидном bundle.** Стратегия 4b (python + `jsonschema`) читала схему и bundle через `open()` без `encoding` → на cp1251-локали любой символ вне cp1251 (эмодзи, типографские кавычки `’`) даёт `UnicodeDecodeError` до начала валидации; ненулевой код python трактовался как «bundle не прошёл схему» → `emit_block` с вводящей в заблуждение причиной. Тот же класс дефекта, что фикс 4a в v0.7.1, и то же последствие — Stop-хук не даёт закрыть сессию. Проверено: 5 из 7 схем репозитория не декодируются в cp1251.
- **`verify-gigacode-hooks.sh` мог тихо отрапортовать ложное «wiring не найден».** `parse_wiring` печатает пути установленного расширения; если в пути есть не-ASCII (напр. `C:\Users\Иван\…`), печать падала, а `2>/dev/null` прятал traceback — вывод выглядел пустым, и доктор сообщал, что привязки хуков не найдены. Добавлен UTF-8 Mode (явный `encoding` на чтении там уже был).

### Added

- **S2.9–S2.11** в `tests/smoke/scripts.sh` — регрессия на локаль-независимость. Кейсы воспроизводят проблему **портируемо**, поэтому ловят регрессию и в Linux-CI, а не только на машине с русской локалью: `PYTHONIOENCODING=cp1251` эмулирует не-UTF-8 вывод, `PYTHONWARNDEFAULTENCODING=1` + `PYTHONWARNINGS=error::EncodingWarning` (PEP 597) превращает любой `open()` без `encoding=` в ошибку. Проверено, что все три кейса красные на коде до фикса и зелёные после. Итого smoke: 72 кейса (33 + 25 + 14).

### Примечание

Затронутые `harness.sh hooks list|status|enable|disable` и `verify-gigacode-hooks.sh` пришли в `main` вместе с чекбокс-UI команды `/harness` — эта функциональность попала в `main` без bump'а версии и записи в CHANGELOG, поэтому отдельной секции для неё здесь нет.

## [v0.7.1] - 2026-08-11

Два места, где harness полагался на послушание модели или дисциплину разработчика вместо детерминированной проверки. Пробелы найдены при сопоставлении репозитория с разбором архитектуры agent-harness'а VS Code / GitHub Copilot ([code.visualstudio.com/blogs/2026/05/15](https://code.visualstudio.com/blogs/2026/05/15/agent-harnesses-github-copilot-vscode)): «harness enforces limits, it doesn't just tell the model» и «harness changes must pass the eval suite before merge».

### Added

- **`implement-iteration-cap-gate.sh`** — 16-й enforcement-хук (PreToolUse · Bash). Делает iteration cap `/implement` детерминированным: блокирует вызов `emit-phase-event.sh`, записывающий 4-ю (и далее) попытку implement-фазы со `status=pass|iterate` вместо обязательного `escalate`. Гейт стоит в единственной точке, где итерация фиксируется durable, — на самом `emit-phase-event.sh` («единственный писатель событий `phase_transition`»). Scope: только `to=implement` (у plan/test/review/evidence задокументированного кэпа нет); неразбираемые аргументы → noop, как в `commit-message-format.sh`.
- **`.github/workflows/harness-ci.yml`** — pre-merge валидация обвязки. На каждый `pull_request`, трогающий `.gigacode/**` или `tests/**`, гоняет `tests/smoke/run-all.sh --verbose` и `.gigacode/scripts/validate-schemas.sh all` на `ubuntu-latest` (+ `workflow_dispatch` для ручного прогона). До этого в репозитории был единственный workflow (`build-gigacode-extension`), который только публикует расширение по push в `main`, и `pull_request`-триггера не было вообще.
- **Suite 11** в `tests/smoke/hooks-extended.sh` + 6 фикстур для нового хука: iteration 3 iterate → allow, iteration 4 iterate → block, iteration 5 pass → block, iteration 4 **escalate → allow** (доказывает, что гейт не over-broad), посторонняя bash-команда → noop, `to=review` iteration 4 → noop. Итого smoke: 67 кейсов (33 + 25 + 9).

### Fixed

- **`evidence-bundle-enforcer.sh` блокировал сессию на любом хосте с Node.** Стратегия 4a звала `npx --yes -p ajv-cli ajv validate -c ajv-formats …`, но `ajv-cli@5` не тянет `ajv-formats` в зависимостях (проверено по npm-реестру) — флаг `-c ajv-formats` требовал require'нуть отсутствующий модуль, npx возвращал ненулевой код, и хук трактовал это как «bundle не прошёл схему», хотя bundle валиден. Добавлен `-p ajv-formats` в вызов (ср. `.gigacode/scripts/_validator.js`, который ставит `ajv@8 + ajv-formats@3` явно). Баг был невидим, потому что: на хосте без Node ветка 4a пропускается и работает jq-smoke, а в smoke-suite его ловит единственный положительный кейс `S1.5` — остальные кейсы Suite 1 и так ожидают блокировку, поэтому системный сбой валидатора в них не проявляется. **Найден первым же прогоном нового `harness-ci`** (Node ставится в job → включается ветка 4a).
- **`dev-metrics-scan.schema.json` не компилировалась валидатором обвязки.** Схема (добавлена в v0.7.0) объявляла `$schema: draft-07`, тогда как `_validator.js` поднимает Ajv в режиме draft 2020-12 (`ajv/dist/2020.js`) и мета-схему draft-07 не знает → `validate-schemas.sh compile` падал на ней. Вдобавок объявление противоречило содержимому: схема использует `$defs` — ключевое слово 2019-09+, в draft-07 его нет (там `definitions`). Приведена к `https://json-schema.org/draft/2020-12/schema`, как остальные 6 схем репозитория. Тоже поймано `harness-ci` — шаг schema-валидации до этого ни разу не выполнялся.
- Счётчики покрытия в шапках `tests/smoke/run-all.sh` и `hooks-extended.sh` отстали ещё с v0.6.0 (заявляли «8 хуков / 13 кейсов», хотя Suite 9–10 для `commit-message-format`/`branch-naming-gate` уже были добавлены). Синхронизированы с фактическим состоянием, там же обновлены числа в README.

### Why

`/implement` документирует iteration cap («Iteration cap: 3. На 4-й попытке — mandatory escalation», GIGACODE.md §9), но ни один хук его не проверял: модель сама читала счётчик через `workflow-state.sh`, сама считала и сама решала остановиться — ровно тот сценарий, от которого предостерегает собственный README harness'а («Модель проигнорировать может — хук нет»). Аналогично требование «после любого изменения хуков или схемы прогнать `tests/smoke/run-all.sh`» существовало только текстом в README и ничем не проверялось.

### Известные ограничения

- **INV-1:** хук перехватывает **запись** 4-й попытки, а не саму 4-ю правку кода — обобщённый PreToolUse-хук не может надёжно связать произвольный Edit/Write с конкретной задачей и итерацией. То же принятое ограничение, что у `sdd-schema-gate.sh` (валидация в момент записи, не раньше).
- **INV-2:** `harness-ci` делает проверку видимой на PR, но **не блокирует merge** сам по себе — required status check включается вручную в branch protection rules и файлами репозитория не настраивается.

## [v0.7.0] - 2026-08-11

### Added

- **`/find-metrics [subpath]` slash command** — офлайн-сканирование Java/Spring Boot проекта на кастомные метрики разработчиков (Micrometer) и генерация `metrics.md`: нумерованный список метрик, сгруппированный по смыслу, без библиотечного шума. Опц. `subpath` сужает область сканирования. Задача класса **R1** (автономная read-only утилита вне PDLC-loop'а; сам `metrics.md` — артефакт вместо evidence bundle).
- **Skill `find-dev-metrics`** (8-й skill в `.gigacode/skills/`) — детектирует регистрацию Counter/Timer/Gauge/DistributionSummary/LongTaskTimer/FunctionTimer/FunctionCounter через `MeterRegistry`, `@Timed`, обёрточные `registerXxx`/`updateXxx`-методы и fluent-builder; извлекает имена метрик (литералы, константы, динамическая конкатенация); фильтрует стандартные метрики фреймворков/библиотек (Spring Boot Actuator, Kafka client/server, Ignite, Tomcat/Jetty/Undertow, Hibernate, Resilience4j, Micrometer internals, Health/Info).
- **Schema `dev-metrics-scan.schema.json`** (7-я schema в `.gigacode/schemas/`) — контракт промежуточного машиночитаемого снапшота скана (`project_root`, `total_custom_metrics`, `metrics_by_type`, `metrics_files`, `unregistered_counters`, `dynamic_metrics_summary`, `excluded_library_metrics`, `scan_metadata`), который skill сохраняет как `{project_root}/.dev-metrics-scan.json` перед рендером `metrics.md` и опционально валидирует через существующий `.gigacode/scripts/validate-schemas.sh validate dev-metrics-scan <file>`.

### Why

Инвентаризация кастомных метрик (что именно и зачем измеряет команда) — рутинная часть онбординга и pre-review в проектах с Micrometer, которую легко автоматизировать детерминированным сканом с explicit-списком библиотечных исключений, чтобы не тонуть в шуме Actuator/Kafka/Ignite/Hibernate.

## [v0.6.11] - 2026-08-10

### Fixed

- 📦 Инструкция обновления в README расширения: `git pull` не работает (extension-репо пере-выкладывается force-push'ем) → правильно `git fetch origin` + `git reset --hard origin/main`, затем переустановить (`/extensions uninstall` → `install`).

## [v0.6.10] - 2026-08-10

### Fixed

- 🩹 Команды больше не зовут несуществующий `.gigacode/scripts/…` из проекта пользователя. Bundled-скрипты/хуки/схемы в командах теперь адресуются через `${extensionPath}/…` (путь установленного расширения — та же переменная, что в манифесте/hooks.json). Раньше `/pdls:harness` и `/pdls:init-project` падали на «нет такого пути».

### Known

- `/pdls:init-project` (copy-модель `init-project.sh`) в flat-раскладке расширения ещё требует доработки. `/pdls:harness` теперь адресуется корректно.

## [v0.6.9] - 2026-08-10

### Fixed

- 🩹 **Namespace `/pdls:` наконец работает.** Команды кладутся в поддиректорию `commands/pdls/<name>.md` — Gemini/GigaCode строит namespace из папки (разделитель пути → двоеточие). Раньше build переименовывал в `pdls_<name>.md`, и GigaCode показывал буквально `/pdls_<name>` (подчёркивание, без двоеточия). Подтверждено докой Gemini CLI (`commands/git/commit` → `/git:commit`).

## [v0.6.8] - 2026-08-10

### Changed

- 📦 Исправлена инструкция установки: install по URL **не поддерживается** — нужно `git clone` + `/extensions install <локальный путь>` изнутри GigaCode. Обновлены README расширения и корневой README.
- 👥 Счётчик в README расширения переключён с hits.sh на **visitor-badge** (уникальные посетители по `page_id`).

## [v0.6.7] - 2026-08-10

### Added

- 👁 Счётчик просмотров README расширения (hits.sh) + бейджи `version`/`license` в шапке.

## [v0.6.6] - 2026-08-10

### Added

- 🔐 Extension теперь шипит `settings.json` (schema v3) с permission-ruleset `deny`/`ask`/`allow` (17/10/11). Раньше build выбрасывал permissions — в манифесте был только `settings: []`, и на GigaCode permission-слой был пуст. Хуки-wiring остаётся в `hooks/hooks.json` (не задваивается).

## [v0.6.5] - 2026-08-10

### Added

- 📚 Расширенная документация README расширения: быстрый старт, control panel `/pdls:harness`, таблица policy-хуков, evidence bundle, troubleshooting.

### Fixed

- README актуализирован под manifest v3: `settings: []`, `hooks/hooks.json`, `name=padelspec-harness` (был устаревший `settings.permissions` и `name=pdls`).

## [v0.6.4] - 2026-08-10

### Changed

- 🎉 Эмоджи в выводе `harness.sh` (control panel): ✅/❌/⚠️ маркеры, 🔧📦🧩 секции doctor, 🪝 hooks list.
- Манифест: `name` → `padelspec-harness` (было `pdls`) — полное имя расширения; namespace команд `/pdls:*` не меняется (держится на именах файлов `pdls_*.md`).

## [v0.6.3] - 2026-08-10

### Changed

- 🎉 Много эмоджи в меню и описании `/pdls:harness` (🩺 doctor · 📋 schemas · 🪝 hooks list/enable/disable) — нагляднее.

## [v0.6.2] - 2026-08-10

### Fixed

- **`/pdls:harness` без аргументов показывает меню подкоманд** (`doctor` · `schemas` · `hooks list/enable/disable`) вместо тихого запуска `doctor`; описание команды дополнено списком подкоманд.

## [v0.6.1] - 2026-08-10

### Fixed

- **GigaCode-расширение устанавливается** (`gigacode extensions link`) — манифест приведён к GigaCode CLI v3: `settings` теперь массив `[]` (устраняет `settings.filter is not a function`); компоненты объявлены строками-путями (`commands/`, `agents/`, `skills/`, `hooks/`); event-wiring хуков вынесен в `hooks/hooks.json`. Реальная проверка на GigaCode CLI.
- **Namespace команд `pdls:`** — файлы собираются с префиксом `pdls_<name>.md` → GigaCode создаёт `/pdls:<name>`; внутренние ссылки между командами обновлены на `/pdls:*`.

## [v0.6.0] - 2026-08-10

### Added

- **GigaCode-расширение (PaDeLSpec)** — дистрибуция harness как расширения GigaCode CLI (Sber): `gigacode-extension.json`, namespace команд `pdls`, `GIGACODE.md`, self-locating хуки (`${extensionPath}` + `HARNESS_ROOT`), runtime-state в `.gigacode/`. Репо: `avoreshin/padelspec_harness_gigacode`.
- **Автосборка плагина** — `scripts/build-gigacode-extension.sh` генерит расширение из `.gigacode/`; GitHub Action `build-gigacode-extension` пересобирает на push и публикует чистой сборкой-коммитом + GitHub Release `vX.Y.Z`. Версия — из файла `VERSION`.
- **2 новых policy-хука (PreToolUse · Bash)** из roadmap P2·06:
  - `commit-message-format.sh` — гейт Conventional Commits (GIGACODE.md §2): блокирует невалидный `git commit -m`; noop на `-F`/`--file`/editor/non-commit.
  - `branch-naming-gate.sh` — гейт имён веток (release-process.md): требует префикс `feat·fix·docs·chore·refactor·test·perf·hotfix·release·agent`; noop на delete/list/базовые ветки.
  - Оба зарегистрированы в `settings.json` (PreToolUse `Bash`), используют `lib/common.sh`. Покрытие: `tests/smoke/hooks-extended.sh` suites 9–10 (good/bad/noop). Всего хуков: 13 → 15.

### Changed

- **Полное покрытие phase-gate диалогов нативным `AskUserQuestion`.** v0.3.2 перевёл на picker 6 команд; оставшиеся интерактивные гейты добивали прозаические `(yes / no)` промпты (диалоговое окно появлялось недетерминированно). Теперь конвертированы все:
  - `sdd-new.md` — step 5 (сбор недостающих полей): risk class подтверждается через picker поверх auto-classify (§4.5), acceptance criteria / SME reviewer остаются свободным вводом.
  - `implement.md` — гейты iterate (<3), last-try (=3) и mandatory-escalation.
  - `continue.md` — все 4 resume-кейса (no-task / pass / iterate / recovery).
  - `workflow.md` — старт orchestration и DONE → `/squash`.
  - `squash.md` — squash-preview и push (force-with-lease / первый push).
  - Каждый гейт сохраняет info-баннер текстом + numbered **fallback** для vendor'ов без picker'а (Codex / GigaCode / Cursor). Прозаических `(yes / no)`-гейтов в `.gigacode/commands/` не осталось.

---

## [v0.5.0] — 2026-07-17

Ветка: `release/v0.5.0` · Tag: `v0.5.0`

Новая команда `/java-linter-review` — офлайн-анализ Java-кода на code smells 3–4 вендоренными линтерами. Добавление (minor bump); существующие команды, хуки и профили не тронуты.

### Added

- **`/java-linter-review [subpath]` slash command** — анализ Java-кода на code smells и генерация markdown-отчёта, где каждая находка содержит три обязательных элемента: **критичность** (High/Medium/Low), **кусок кода** (файл + строка) и **предметную рекомендацию**. Опц. `subpath` сужает область анализа. Задача класса **R1** (автономная read-only утилита вне PDLC-loop'а; сам отчёт — артефакт вместо evidence bundle).
- **Гибридная архитектура (token discipline §8):** детерминированный bash-слой `.gigacode/scripts/java-lint.sh` запускает линтеры → SARIF/XML, а изолированный субагент читает verbose-вывод в своём контекстном окне и возвращает в основной диалог только summary + путь.
- **Субагент `java-lint-review`** (7-й профиль в `.gigacode/agents/`) — нормализует severity разных линтеров в единую шкалу, дедуплит находки, вырезает сниппеты, пишет отчёт **строго по образцу**. Tool-scope: `Read, Grep, Glob, Bash, Write` (read-only по исходникам, единственная запись — файл отчёта).
- **Вендоренные линтеры** `.gigacode/vendor/java-linters/` (~114 МБ, офлайн, стратегия A): **PMD 7.8.0**, **Checkstyle 10.21.0**, **PMD-CPD** (в дистрибутиве PMD), **SpotBugs 4.8.6** — скачаны с официальных GitHub Releases, версии зафиксированы в `versions.lock`, целостность ключевых jar сверяется по `checksums.sha256` (SHA-256) перед каждым прогоном. Единственная внешняя зависимость — **JDK 17+**.
- **Rulesets** `.gigacode/vendor/java-linters/rulesets/` — curated smell-подмножества `pmd-smells.xml` (design / bestpractices / errorprone) и `checkstyle-smells.xml` (структурные smells; чистый codestyle-нитпик исключён).
- **Policy-as-code** `.gigacode/policies/java-lint-severity.yaml` — детерминированный маппинг нативных приоритетов линтеров (PMD priority, Checkstyle severity, SpotBugs rank, CPD lines) → High/Medium/Low, правила дедупликации, нормализованные категории.
- **Шаблон отчёта** `.gigacode/templates/java-lint-report.md` — по эталону `java-linter-2026-07-17.md`: `# Code Smell Report` → **«По файлам»** (группировка по файлам) → **«Топ-5 категорий»** → **«Детальные заметки»** → **«Итого»**.
- **Гарантированный отчёт:** `java-lint.sh` создаёт файл `linter-reports/java-linter-<ts>.md` (baseline) на **любом** пути выхода (success / no_java / нет JDK / нет линтеров) + симлинк `latest.md`; субагент перезаписывает тот же файл обогащённым отчётом. Папка `linter-reports/` — в `.gitignore`.
- **Гейт сборки для SpotBugs:** после каждого успешного прогона команда через `AskUserQuestion` спрашивает разрешение на `mvn clean package -DskipTests=true`; при согласии проект собирается (без тестов) и SpotBugs прогоняется по свежим классам (phase 2, флаг `--build-spotbugs`).
- **Флаги CI:** детерминированные счётчики находок (`total_findings`, per-linter `count:`), SHA-256 integrity-gate (`--no-verify` для обхода), `--fail-on <any|high|N>` (exit 5 для pipeline), `--keep`, `--min-tokens N` для CPD.
- **Smoke** `tests/smoke/java-lint.sh` (29 кейсов: Tier A discovery/ветки, Tier B контракт SARIF/XML-артефактов, Tier C счётчики/integrity/latest/fail-on) + fixtures `tests/fixtures/java-lint/{single,multimodule,maven,nojava}` с умышленными smells. Guard: SKIP при отсутствии JDK 17+ / линтеров (suite остаётся зелёным).

### Обязательные проверки (всегда присутствуют в отчёте)

- **Неиспользуемые переменные / методы / импорты (dead code)** — PMD (`UnusedPrivateField/Method`, `UnusedLocalVariable`, `UnusedFormalParameter`, `UnusedAssignment`, `UnnecessaryImport`) + Checkstyle (`UnusedImports`, `RedundantImport`, `UnusedLocalVariable`). Отдельная секция + действие REMOVE в рекомендациях.
- **Нарушения SOLID** — секция с оценкой по каждому принципу (SRP/OCP/LSP/ISP/DIP). SRP опирается на структурные сигналы PMD design-категории (`GodClass`, `TooManyMethods`, `TooManyFields`, `ExcessiveParameterList`, `CouplingBetweenObjects`, сложность) + ревью субагента. Пустой раздел не допускается.

### Why

Ревью Java-кода на структурные болячки (дублирование, god-класс, мёртвый код, нарушения SRP) — рутинная часть code-review, которую детерминированно закрывают индустриальные линтеры. Команда даёт это офлайн, воспроизводимо и с отчётом, сразу пригодным к работе (критичность + код + рекомендация).

### Design invariants

- **INV-1:** линтеры едут внутри harness — агент вызывает их прямо из папки, без сетевой докачки. JVM — единственное, что не вендорится.
- **INV-2:** verbose-вывод линтеров не попадает в основной контекст — только summary + путь (§8 token discipline).
- **INV-3:** отчёт создаётся на диске всегда, даже при отсутствии Java / JDK / линтеров (degraded baseline).
- **INV-4:** обязательные проверки (dead code + SOLID) присутствуют в каждом отчёте, даже с вердиктом «Не обнаружено».
- **INV-5:** supply-chain tripwire — сверка SHA-256 ключевых jar перед прогоном; несовпадение → `integrity: FAIL` + предупреждение в отчёте.

---

## [v0.4.1] — 2026-06-20

Ветка: `release/v0.4.1` · Tag: `v0.4.1`

### Changed (UX)

- **`/sdd-new` → worktree isolation.** После approve SDD команда спрашивает (через `AskUserQuestion`), вести ли задачу в изолированном `git worktree` (`.worktrees/<slug>/` на `agent/<slug>`). На «Create worktree» сразу запускается `agentic-worktree.sh start <slug>`, и весь downstream loop (plan → test → implement) идёт в изоляции от main checkout. Для R2+ выбор «main checkout» помечается как отступление от §4.5 risk ladder и фиксируется в evidence bundle. Использует backport'нутые в v0.4.0 skill `agentic-worktree` + `.gigacode/scripts/agentic-worktree.sh`.

---

## [v0.4.0] — 2026-06-20

Ветка: `release/v0.4.0` · Tag: `v0.4.0`

Бэкпорт PDLC-артефактов из working repo (`pdlc-harness-work`) в дистрибутив. Все изменения — **добавления** (minor bump); существующие команды и профили не трогались.

### Added

- **Skills (6)** портированы из рабочего harness:
  - `agentic-worktree` — lifecycle per-task git worktree (изоляция Coding subagent на R2+).
  - `context-compact` — 5-уровневый pipeline компакции контекста (§2.10).
  - `evidence-bundle-build` — сборка обязательного evidence bundle.
  - `harness-principles` — чек-лист 13 принципов Harness-over-Model перед R3+ SDD (§2.2).
  - `mob-elaboration` — совместная проработка задачи.
  - `risk-classify-deep` — углублённая классификация risk class (R0–R5).
- **Schemas (4):** `sdd`, `dora-baseline`, `phase-transition`, `risk-ladder` — JSON Schema для валидации артефактов.
- **Hook:** `sdd-schema-gate.sh` — зарегистрирован как PostToolUse на `Write|Edit|MultiEdit` в `settings.json`; авто-валидация SDD по `sdd.schema.json`. Блокирует (`decision:block`, exit 2) malformed SDD, проходит валидные, gracefully no-op при отсутствии validator/Node.
- **Validator subsystem** в `.gigacode/scripts/`:
  - `validate-schemas.sh` — CLI-валидатор (`validate sdd <file>`, `validate dora <file>`, fixtures).
  - `_validator.js` — обёртка над ajv@8 + ajv-formats@3 + js-yaml@4; self-bootstrap npm-зависимостей в `.gigacode/.cache/node/` при первом запуске.
  - `extract-sdd-frontmatter.sh`, `extract-dora-frontmatter.sh` — markdown frontmatter → JSON.
  - `agentic-worktree.sh` — реализация worktree lifecycle (start/finish/list/prune).
  - `check-phase-transition.sh` — валидация structured phase-transition output агента по `phase-transition.schema.json`.

### Changed

- Пути в портированных скриптах и в `sdd-schema-gate.sh` адаптированы под дистрибутив-layout (`.gigacode/scripts/` вместо root `scripts/`); cache validator'а резолвится в `.gigacode/.cache/node/`.
- `.gitignore`: добавлен `.gigacode/.cache/` (self-bootstrap node_modules не коммитятся).

### Fixed

- **Layout-несоответствие путей.** Все ссылки на скрипты в командах (`continue`, `squash`, `evidence`, `implement`, `plan`, `sdd-new`, `test`), skill `agentic-worktree`, схемах и хуке перенацелены с root `scripts/…` на фактическое место поставки `.gigacode/scripts/…`. Раньше команды ссылались на несуществующие в дистрибутиве пути.
- Устаревший hint в `sdd-schema-gate.sh` (`Run scripts/install-harness.sh` — этот installer не входит в дистрибутив) заменён на актуальный (Node.js + `chmod +x`).

---

## [v0.3.2] — 2026-05-31

Ветка: `release/v0.3.2` · Tag: `v0.3.2`

### Changed (UX)

- **Interactive phase-gates** во всех 6 командах с переходами фаз (`sdd-new`, `plan`, `test`, `implement`, `review`, `evidence`). Вместо «введите yes / no» — нативный picker `AskUserQuestion` с кликабельными вариантами:
  - `plan`: Continue → /test · Iterate · Revise SDD · Stop
  - `test`: Continue → /implement · Add more tests · Stop (+ recovery branch для status≠pass)
  - `implement`: Continue → /review · Iterate · Stop
  - `review`: 3 branches по verdict — APPROVE / REJECT major / REJECT critical, каждый со своим picker'ом
  - `evidence`: DONE → Squash/Keep atomic/Hold · Fix bundle · Back to /implement
  - `sdd-new`: Continue → /plan · Skip to /test · Use /workflow · Stop & review
- **Vendor-aware fallback:** для CLI без `AskUserQuestion` (Codex / Gemini CLI / GigaCode / Cursor) — numbered text options. Pattern документирован в каждой команде.

### Why

Текущий «жди yes/no» — frictional UX: пользователь тайпит вместо клика, ошибки тайпа возможны (особенно кириллицей), варианты не видны явно. Picker делает phase-gate **видимым** (все варианты на экране) и **точным** (audit фиксирует `selected: continue`, а не текст-парсинг «yes»).

### Design invariants

- **INV-1:** auto-mode (R0/R1 через `/workflow` при `status=pass`) пропускает picker без изменений — это backward-compatible.
- **INV-2:** failure / iterate / escalate всегда показывают picker (INV-3 Phase Gate Protocol).
- **INV-3:** vendor без picker получает text-fallback — функциональность не теряется, только UX.
- **INV-4:** hook contracts и enforcement не затронуты — это patch (v0.3.2), не minor.

---

## [v0.3.1] — 2026-05-31

Ветка: `release/v0.3.1` · Tag: `v0.3.1`

### Added

- **`tests/` top-level директория** для всей regression / smoke инфраструктуры обвязки. Заменяет хранение тестов внутри `.gigacode/scripts/`.
- **`tests/smoke/hooks-extended.sh`** — file-fixture smoke suite для 8 хуков, не покрытых `hooks-core.sh`: `pii-boundary-check`, `cost-circuit-breaker`, `prompt-validator`, `slash-command-lint`, `ai-code-quality-gate`, `jsonl-audit-sink`, `subagent-stop-validator`, `context-integrity-review`. 13 кейсов. Sandbox через trap-restore `.gigacode/.cost/`.
- **`tests/smoke/scripts.sh`** — smoke для `.gigacode/scripts/workflow-state.sh`: usage error, synthetic task (planted audit), unknown task. 3 кейса.
- **`tests/smoke/run-all.sh`** — агрегатор T1 (hooks-core 33) + T2 (hooks-extended 13) + T3 (scripts 3) = **49 кейсов** одной командой.
- **`tests/fixtures/hooks/`** — 11 JSON stdin payloads, naming `<hook>-<case>.json`. + README.
- **`tests/fixtures/scripts/`** — synthetic phase-transition audit для workflow-state.
- **`tests/README.md`** — описание структуры, тиров, запуска, что НЕ покрыто smoke-уровнем + migration note для пользователей с форками.

### Changed

- **`.gigacode/scripts/test-hooks.sh` переименован в `tests/smoke/hooks-core.sh`** (git mv — история сохранена). HARNESS_ROOT path остался `../..` (та же глубина от нового расположения). Все 33 кейса по-прежнему зелёные.
- **README.md** обновлён:
  - Badge версии: `v0.3.0 → v0.3.1`.
  - Версия-таблица: новая строка `v0.3.1`.
  - `.gigacode/scripts/` tree уже не показывает `test-hooks.sh` (он переехал в `tests/`).
  - Новая секция `tests/` describing smoke suite.
  - Установка: команда smoke-test обновлена с `bash .gigacode/scripts/test-hooks.sh` на `bash tests/smoke/run-all.sh`.
  - Section «Что трогать осторожно» — путь к test-hooks обновлён.
- **`.gigacode/docs/CUSTOMIZATION.md`** — 3 ссылки на `.gigacode/scripts/test-hooks.sh` обновлены на новый путь + указание на 2 файла (hooks-core + hooks-extended).

### Migration

Пользователям, форкнувшим harness и держащим свои сценарии в `.gigacode/scripts/test-hooks.sh`:

```bash
# В вашем форке:
git merge upstream/main          # merge переименует файл через git mv
# или вручную:
git mv .gigacode/scripts/test-hooks.sh tests/smoke/hooks-core.sh
# дополните своими сценариями уже в новом файле
```

Старые ссылки в CI / pre-commit hook'ах обновить:

```diff
- bash .gigacode/scripts/test-hooks.sh
+ bash tests/smoke/run-all.sh      # покрывает оба + scripts
# или для совместимости — только legacy:
+ bash tests/smoke/hooks-core.sh
```

### Design invariants

- **INV-1:** существующее покрытие хуков (`hooks-core.sh` = бывший `test-hooks.sh`) **не урезано**. 33 кейса остались inline, идентичны.
- **INV-2:** новые fixtures — additive only. `hooks-extended.sh` не дублирует `hooks-core.sh`.
- **INV-3:** работающие хуки и GigaCode контракт не затронуты. Релиз — patch (v0.3.1), а не minor.

---

## [v0.3.0] — 2026-05-23

Ветка: `release/v0.3.0` · Tag: `v0.3.0`

### Added

- **`/workflow <slug>` orchestrator-команда.** Ведёт через весь loop (plan→test→implement→review→evidence):
  - **auto-mode** для R0/R1: confirm только при `status ≠ pass`
  - **manual-mode** для R2+: confirm на каждом transition (existing behavior)
  - Failure always asks user — INV-3, auto-mode не bypass-ит failures
- **`/continue <task-id>`** — resume workflow с last phase per audit-trail. 5 case branches: not found / pass / iterate / fail|escalate / done.
- **`/squash <task-id>`** — soft-reset feature branch в один логический коммит с aggregated Conventional Commits message. Hard error на main/release branches. Force-push идёт через existing `ask` ladder в `settings.json` (double-confirm — намеренно).
- **`.gigacode/scripts/workflow-state.sh`** — bash helper, парсит `.gigacode/audit/*.jsonl` `phase_transition` events, выдаёт `{current_phase, last_status, iteration, started_at, next_recommended_command}` в `--json` (default) или `--text` формате.

### Changed

- **README.md** обновлён под v0.3.0:
  - Badge версии: `v0.2.0 → v0.3.0`.
  - Секция «Версии и история изменений» дополнена строками v0.2.1 и v0.3.0.
  - Список commands расширен с 9 до 12 (`/workflow`, `/continue`, `/squash`).
  - Дерево `.gigacode/` теперь показывает `scripts/` директорию (включая `workflow-state.sh`).
  - Workflow diagram расширен «Orchestrator path» под `/workflow` и упоминанием `/squash` перед PR.
  - Пример `git clone --branch v0.3.0` для pin к версии.
- **6 существующих slash-commands** получили Tip-секции с references на новые:
  - `/sdd-new` → tip на `/workflow` (R0/R1 auto-mode) + `/continue` (resume)
  - `/plan`, `/test`, `/review` → tip на `/continue`
  - `/implement` → tip на `/continue` (включая iteration counter restore)
  - `/evidence` → tip на `/squash` после DONE + `/continue` resume

### Design invariants

- **INV-1:** workflow state derived из audit-trail. Никакого separate state-файла — single source of truth.
- **INV-2:** auto-mode hard-deny для R2+ задач — decision по `risk_class` из SDD frontmatter.
- **INV-3:** failure всегда ждёт user (даже в auto-mode).
- **INV-4:** никакого git mutation без user confirmation (squash + push = irreversible action → double-confirm).

---

## [v0.2.1] — 2026-05-23

Ветка: `release/v0.2.1` · Tag: `v0.2.1` · Commit: `f5dd9d3`

### Changed

- **README.md** обновлён под v0.2.0:
  - Добавлен badge `version-v0.2.0` в шапке.
  - Новая секция «Версии и история изменений» — таблица release branches + tags + ссылка на CHANGELOG.
  - Список commands расширен с 6 до 9 (`/init-project`, `/test`, `/implement`).
  - Список hooks расширен с 10 до 12 (`test-files-protector`, `gigacode-md-placeholders`).
  - Workflow diagram перерисован: явные `/test` / `/implement` фазы, iteration counter loop, recovery branches (REJECT major / critical / AC failed / schema invalid).
  - Пример `git clone --branch v0.2.0` для pin к версии.

---

## [v0.2.0] — 2026-05-23

Ветка: `release/v0.2.0` · Tag: `v0.2.0` · Commit: `350f4f1`

### Added

- **`/test` slash command** — entry point для TDD-фазы; делегирует на `test` subagent с context'ом из SDD. Раньше требовался natural-language вызов («запусти test agent для X»). [SDD-20260523-interactive-loop-orchestration]
- **`/implement` slash command** — Implement-фаза с iteration counter (1..3) и mandatory escalation на iter=3 (см. §9 GIGACODE.md). Закрывает gap «команды tdd нет?» из пользовательского feedback 2026-05-22.
- **«Next step (Phase Gate)» секции** в существующих командах `/sdd-new`, `/plan`, `/review`, `/evidence` — после каждой фазы Claude явно предлагает следующий шаг (с подтверждением) или recovery action из `loop-recovery.md` при failure. Recovery decision встроена в каждый command-файл.
- `CHANGELOG.md` — этот файл.
- `docs/release-process.md` — workflow обновлений: feature branches → main → release branches + tags.

### Changed

- `/review` command — добавлена 3-way decision table: `APPROVE` → `/evidence`, `REJECT major` → `/implement`, `REJECT critical` → `/sdd-new` (architectural rollback, human required).
- `/evidence` command — done-state проверка: schema valid + all AC passed → `done`; иначе self-loop fix bundle или rollback на `/implement`.

### Pending (will land later — backport из `pdlc-harness-work`)

Эти артефакты упомянуты в обновлённых commands, но физически ещё не в репо. Перенос отдельным коммитом:

- `scripts/check-phase-transition.sh` — validates structured agent output.
- `scripts/_validator.js`, `validate-schemas.sh` — JSON Schema runner.
- `docs/playbooks/loop-state-machine.md`, `loop-recovery.md` — state machine + recovery decision table.
- 5 schemas: `sdd`, `dora-baseline`, `risk-ladder`, `audit-event`, `phase-transition`.

---

## [v0.1.0] — 2026-05-16

Ветка: `release/v0.1.0` · Tag: `v0.1.0` · Commit: `1b13ef7`

Initial release pdlc-harness. Базовая обвязка для GigaCode согласно AI DISRUPT PDLC v3.5.

### Added (от initial commit `575d3ea` до `1b13ef7`)

- **6 slash-commands** (`.gigacode/commands/`): `/sdd-new`, `/plan`, `/review`, `/evidence`, `/metrics`, `/risk-classify`.
- **`/init-project` command** — однокомандная установка harness'а в свежий repo с заполнением GIGACODE.md placeholders через AskUserQuestion. [`feat(init): one-command harness install via /init-project`]
- **6 subagent profiles** (`.gigacode/agents/`): `explore`, `plan`, `test`, `coding`, `review`, `security` — с per-role tool scope.
- **10+ enforcement hooks** (`.gigacode/hooks/`): `destructive-command-blocker`, `pii-boundary-check`, `evidence-bundle-enforcer`, `cost-circuit-breaker`, `prompt-validator`, `ai-code-quality-gate`, `context-integrity-review`, `subagent-stop-validator`, `slash-command-lint`, `jsonl-audit-sink`, plus новые: `test-files-protector`, `gigacode-md-placeholders`.
- **`test-files-protector.sh`** PreToolUse hook — блокирует Edit/Write для test files без `PDLC_ALLOW_TEST_EDIT=1`. [`feat(hooks): block edits to test files without explicit Test Agent opt-in`]
- **`gigacode-md-placeholders.sh`** SessionStart hook — warning, если в `.gigacode/GIGACODE.md` остались `<…>` placeholders. [`feat(hooks): SessionStart warns about unfilled GIGACODE.md placeholders`]
- `.gigacode/settings.json` — policy hooks framework (deny-first для destructive ops, secrets, evidence bundle enforcement).
- `.gigacode/schemas/evidence-bundle.schema.json` — single schema на этой версии.
- `.gigacode/templates/SDD-template.md`, `GIGACODE.md` template.
- `.gigacode/policies/risk-ladder.yaml` — R0..R5 maturity ladder.
- `.gigacode/scripts/` — `init-project.sh`, `collect-evidence.sh`, `test-hooks.sh`.

### Changed (от initial release)

- **Schema enforcement** evidence-bundle: validator теперь верифицирует **содержимое**, не только наличие файла. [`fix(hooks): evidence-enforcer now verifies content, not just schema`]
- **`/evidence`** стала executable, а не просто prompt'ом. [`feat(evidence): make /evidence executable, not just a prompt`]
- **`evidence-bundle.schema.json`** — формализованы `git_context` и `test_hint`, enforce для R2+. [`feat(schema): formalize git_context and test_hint, enforce for R2+`]

### Documentation

- `README.md` — обзор drop-in `.gigacode/` для любого репо.
- `docs/customization.md` — how to adapt the harness без поломки. [`docs(customization): how to adapt the harness without breaking it`]

### Tests

- `tests/` — regression suite для harness hooks. [`feat(tests): regression suite for the harness hooks`]

---

## Release tooling

- **Release branches** — каждая `vX.Y.Z` фиксируется веткой `release/vX.Y.Z`, которая создаётся от main на момент release и больше не двигается (только hotfix patch'и).
- **Tags** — `vX.Y.Z` — immutable, ставятся на тот же commit, что HEAD release-ветки.
- **Conventional Commits** — `feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...`, `refactor(scope): ...`, `chore(scope): ...`.
- Workflow подробно: [`docs/release-process.md`](docs/release-process.md).
