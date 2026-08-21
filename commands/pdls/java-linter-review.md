---
description: Анализ Java code smells 3-4 вендоренными линтерами (PMD, Checkstyle, PMD-CPD, SpotBugs) → markdown-отчёт по образцу с критичностью, кодом и рекомендациями. Обязательно проверяет неиспользуемые переменные/методы/импорты и нарушения SOLID
---

Проанализируй Java-код текущего проекта на code smells: {{args}} (опц. subpath для сужения области; пусто — весь репозиторий).

**Тип задачи:** автономная read-only утилита, **R1** (вне PDLC-loop'а, без обязательного evidence bundle — сам отчёт является артефактом).

**Mandate:** делегировать весь анализ в изолированный субагент ради token discipline (§8 GIGACODE.md). Основной контекст получает только summary + путь к отчёту.

## Процесс

1. **Делегируй в субагент `java-lint-review`** через Task (`subagent_type: "java-lint-review"`). Передай опц. `subpath` из `{{args}}`.

2. Субагент сам:
   - запустит `${extensionPath}/scripts/java-lint.sh` (детект JDK 17+, discovery `src/main`/`src/test`, запуск вендоренных линтеров → SARIF/XML);
   - **скрипт ГАРАНТИРОВАННО создаёт файл отчёта** `linter-reports/java-linter-<ts>.md` (baseline) на любом пути выхода — путь лежит в манифесте (`report_file:`);
   - субагент читает вывод, нормализует severity в High/Medium/Low, дедуплит;
   - вырежет сниппеты кода и **перезапишет тот же `report_file`** обогащённым отчётом **строго по образцу** `${extensionPath}/templates/java-lint-report.md` (группировка по файлам → Топ-5 категорий → Детальные заметки → Итого);
   - **обязательно** включит две проверки (присутствуют всегда): (a) неиспользуемые переменные/методы/импорты — dead code; (b) нарушения SOLID (SRP/OCP/LSP/ISP/DIP);
   - вернёт summary + путь.

3. **Обработай результат субагента (phase 1):**
   - Нет JDK 17+ → сообщи инструкцию по установке, не выдумывай отчёт. **Гейт сборки не показывай.**
   - Линтеры не вендорены → сообщи, что нужен vendoring. **Гейт сборки не показывай.**
   - Java не найдена → передай, что `src/main`/`src/test` не обнаружены. **Гейт сборки не показывай.**
   - Успех → покажи summary и путь к отчёту, затем перейди к шагу 4.

4. **Обязательный гейт сборки для SpotBugs (после КАЖДОГО успешного прогона).**
   Из summary/манифеста субагента определи состояние SpotBugs (`linter: spotbugs status=...`) и Maven (`build_tool: maven pom=... mvn_available=...`):
   - Если SpotBugs **уже** отработал (`status=ok`, классы были) → сообщи это, гейт можно пропустить (собирать нечего).
   - Если `pom=none` **или** `mvn_available=0` → сообщи, что автосборка невозможна (нет Maven-проекта или не установлен `mvn`), и не предлагай no-op.
   - Иначе (SpotBugs пропущен, есть pom.xml и mvn) → **вызови `AskUserQuestion`**:
     - `question`: "SpotBugs требует скомпилированных классов. Запустить `mvn clean package -DskipTests=true` и прогнать SpotBugs?"
     - `header`: "Build+SpotBugs?"
     - `options`:
       - `label`: "Да, собрать и прогнать SpotBugs" · `description`: "Выполнить mvn clean package -DskipTests=true, затем SpotBugs; дополнить отчёт."
       - `label`: "Нет, оставить отчёт как есть" · `description`: "SpotBugs останется пропущенным."
     - **Fallback** (CLI без picker'а): напечатай оба варианта numbered и жди INPUT.

5. **Если пользователь согласился на сборку** → **повторно делегируй в субагент `java-lint-review`** (phase 2) с инструкцией запустить `${extensionPath}/scripts/java-lint.sh <subpath> --build-spotbugs` (субагент выполнит `mvn clean package -DskipTests=true`, прогонит SpotBugs и **дополнит тот же отчёт** секцией SpotBugs). Верни обновлённый summary.
   - Если сборка упала (`build: mvn rc≠0`) → сообщи об ошибке со ссылкой на `linter-reports/.tmp/mvn-build.log`, отчёт без SpotBugs остаётся валидным.

## Output (в чат)

```
## Java Linter Review — summary
Файлов Java: <N> · Линтеры: PMD ✓ / Checkstyle ✓ / CPD ✓ / SpotBugs <✓|skipped|built>
Smells: High <a> · Medium <b> · Low <c>  (всего <N>)
Топ-категории: <...>
📄 Отчёт: linter-reports/java-linter-<ts>.md
```

**Примечание:** команда не является фазой loop'а — phase-gate transition не выполняется.
