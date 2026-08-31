#!/usr/bin/env bash
# java-lint.sh — deterministic-слой команды /java-linter-review.
#
# Что делает (и НЕ делает):
#   - детектит JDK 17+ (единственная внешняя зависимость);
#   - рекурсивно находит src/main и src/test в текущем проекте;
#   - гоняет ВЕНДОРЕННЫЕ линтеры из <harness>/vendor/java-linters/:
#       PMD, Checkstyle, PMD-CPD (всегда) + SpotBugs (best-effort, если есть
#       скомпилированные классы — БЕЗ авто-сборки);
#   - складывает сырой вывод (SARIF/XML) в linter-reports/.tmp/;
#   - печатает манифест (какие линтеры отработали, пути к файлам, src-roots)
#     в stdout И в linter-reports/.tmp/manifest.txt.
#
# Что НЕ делает: не нормализует, не дедуплит, не пишет отчёт, не парсит SARIF.
# Это делает изолированный субагент java-lint-review (§8 GIGACODE.md, token
# discipline). Скрипт зависит ТОЛЬКО от JDK — никаких python/jq.
#
# Exit codes:
#   0 — прогон завершён (в т.ч. если линтеры нашли smells ИЛИ Java не найден).
#   3 — нет JDK 17+.
#   4 — не найдены вендоренные линтеры (нужен bootstrap/vendoring).
#   5 — сработал --fail-on (для CI-гейта; отчёт при этом всё равно записан).
#
# Гарантия: файл отчёта linter-reports/java-linter-<ts>.md (+ latest.md) пишется
# на ЛЮБОМ пути выхода. Манифест содержит детерминированные счётчики находок
# (count:/total_findings:/high_findings:) и результат сверки целостности jar.
#
# SpotBugs (best-effort): по умолчанию запускается ТОЛЬКО если уже есть
# скомпилированные классы. С флагом --build-spotbugs скрипт сам выполнит
# `mvn clean package -DskipTests=true` (если есть pom.xml и mvn) и затем SpotBugs.
# Разрешение на сборку запрашивает команда/оркестратор, не скрипт.
#
# Пути:
#   ресурсы (линтеры, ruleset'ы) — рядом со скриптом: .gigacode/ или ${extensionPath}/;
#   анализируемый проект и отчёты — рабочая директория (git root, если внутри
#   репозитория). Переопределяются переменными HARNESS_ROOT и
#   JAVA_LINT_PROJECT_ROOT.
#
# Usage:
#   bash .gigacode/scripts/java-lint.sh [subpath] [--min-tokens N] [--keep]
#        [--build-spotbugs] [--fail-on <any|high|N>] [--no-verify]

# ВАЖНО: без `-e` — линтеры возвращают ненулевой код, когда находят проблемы.
set -uo pipefail

# ---------------------------------------------------------------------------
# Пути
# ---------------------------------------------------------------------------
# Два независимых корня. Раньше был один — «каталог, где лежит .gigacode/» — и от
# него считались И ресурсы линтеров, И каталог отчётов. При drop-in установке эти
# два совпадают, поэтому расхождение не замечалось; в GigaCode-расширении
# скрипт живёт в ${extensionPath}/scripts/, и тот же расчёт уводил вывод
# в родительский каталог установленного расширения, а не в анализируемый проект.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1) HARNESS_ROOT — ресурсы обвязки: вендоренные линтеры, ruleset'ы, checksums.
#    Лежат рядом со скриптом: .gigacode/ при drop-in, ${extensionPath}/ в GigaCode.
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
VENDOR="$HARNESS_ROOT/vendor/java-linters"
RULESETS="$VENDOR/rulesets"

# 2) PROJECT_ROOT — что анализируем и куда пишем отчёт. Это рабочая директория,
#    а не место установки обвязки. Переопределяется JAVA_LINT_PROJECT_ROOT.
PROJECT_ROOT="${JAVA_LINT_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
OUT_DIR="$PROJECT_ROOT/linter-reports"
TMP_DIR="$OUT_DIR/.tmp"
MANIFEST="$TMP_DIR/manifest.txt"

# ---------------------------------------------------------------------------
# Аргументы
# ---------------------------------------------------------------------------
SUBPATH=""
MIN_TOKENS=50   # порог CPD: ловит метод-уровневые дубли; переопределяется --min-tokens
KEEP=0
BUILD_SPOTBUGS=0   # --build-spotbugs: разрешить `mvn clean package -DskipTests=true` ради SpotBugs
FAIL_ON=""         # --fail-on <any|high|N>: exit 5 для CI-гейта (по умолчанию всегда exit 0)
VERIFY=1           # --no-verify: пропустить сверку SHA-256 вендоренных jar
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-tokens)     MIN_TOKENS="${2:-100}"; shift 2 ;;
    --keep)           KEEP=1; shift ;;
    --build-spotbugs) BUILD_SPOTBUGS=1; shift ;;
    --fail-on)        FAIL_ON="${2:-any}"; shift 2 ;;
    --no-verify)      VERIFY=0; shift ;;
    -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
    -*)               echo "[java-lint] unknown flag: $1" >&2; exit 2 ;;
    *)                SUBPATH="$1"; shift ;;
  esac
done

SCAN_ROOT="$PROJECT_ROOT"
if [[ -n "$SUBPATH" ]]; then
  if [[ -d "$SUBPATH" ]]; then SCAN_ROOT="$(cd "$SUBPATH" && pwd)"
  elif [[ -d "$PROJECT_ROOT/$SUBPATH" ]]; then SCAN_ROOT="$(cd "$PROJECT_ROOT/$SUBPATH" && pwd)"
  else echo "[java-lint] subpath not found: $SUBPATH" >&2; exit 2
  fi
fi

log() { echo "[java-lint] $*" >&2; }

# ---------------------------------------------------------------------------
# Манифест + гарантированный baseline-отчёт
# ---------------------------------------------------------------------------
# Манифест инициализируется СРАЗУ, чтобы отчёт можно было записать на ЛЮБОМ
# пути выхода (нет JDK / нет линтеров / нет Java / успех).
mkdir -p "$TMP_DIR"
: > "$MANIFEST"
emit() { echo "$*"; echo "$*" >> "$MANIFEST"; }

# Путь отчёта фиксируется здесь и передаётся субагенту через манифест —
# субагент ПЕРЕЗАПИШЕТ этот же файл обогащённой версией (без дублей).
REPORT_FILE="$OUT_DIR/java-linter-$(date +%Y%m%d-%H%M%S).md"
emit "manifest_version: 1"
emit "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
emit "harness_root: $HARNESS_ROOT"
emit "project_root: $PROJECT_ROOT"
emit "scan_root: $SCAN_ROOT"
emit "report_file: $REPORT_FILE"
emit "latest: $OUT_DIR/latest.md"
emit "min_tokens: $MIN_TOKENS"

# Детерминированный baseline-отчёт из манифеста. ГАРАНТИЯ: файл отчёта на диске
# существует всегда после запуска, даже если субагент java-lint-review не
# отработает. Субагент потом перезапишет $REPORT_FILE обогащённым отчётом.
write_baseline_report() {
  local status scan jdk jcount total integ
  status="$(grep -E '^status:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  scan="$(grep -E '^scan_root:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  jdk="$(grep -E '^jdk_major:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  jcount="$(grep -E '^java_file_count:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  total="$(grep -E '^total_findings:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  integ="$(grep -E '^integrity:' "$MANIFEST" | head -1 | cut -d' ' -f2-)"
  mkdir -p "$OUT_DIR"
  {
    echo "# Java Linter Review — $(basename "${scan:-project}") — $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "> ⚙️ Baseline-отчёт, сгенерирован \`java-lint.sh\` детерминированно (гарантированный артефакт)."
    echo "> Субагент \`java-lint-review\` заменяет его обогащённым отчётом (severity, сниппеты, рекомендации)."
    echo
    echo "## Summary"
    echo "- Статус: \`${status:-unknown}\`"
    echo "- Java-файлов: ${jcount:-0}"
    echo "- Сырых находок (до дедупликации): ${total:-0}"
    echo "- Целостность вендоренных jar: \`${integ:-unknown}\`"
    echo "- JDK: ${jdk:-?}"
    echo "- Scan root: \`${scan:-?}\`"
    echo
    echo "### Линтеры"
    if grep -qE '^linter:' "$MANIFEST"; then
      grep -E '^linter:' "$MANIFEST" | sed 's/^linter: /- /'
    else
      echo "- (не запускались)"
    fi
    if grep -qE '^build:' "$MANIFEST"; then
      echo; echo "### Сборка"
      grep -E '^build:' "$MANIFEST" | sed 's/^build: /- /'
    fi
    if grep -qE '^note:' "$MANIFEST"; then
      echo; echo "### Заметки"
      grep -E '^note:' "$MANIFEST" | sed 's/^note: /- /'
    fi
    echo
    echo "## Сырые результаты"
    echo "- \`linter-reports/.tmp/\`: pmd.sarif, checkstyle.sarif, cpd.xml, spotbugs.sarif (если есть)"
    echo "- Манифест: \`linter-reports/.tmp/manifest.txt\`"
  } > "$REPORT_FILE"
  # #5 — стабильный указатель latest.md на последний отчёт (симлинк; субагент
  # перезапишет $REPORT_FILE, а симлинк продолжит указывать на актуальную версию).
  ln -sf "$(basename "$REPORT_FILE")" "$OUT_DIR/latest.md" 2>/dev/null \
    || cp -f "$REPORT_FILE" "$OUT_DIR/latest.md" 2>/dev/null || true
  log "baseline report → $REPORT_FILE (latest.md → $(basename "$REPORT_FILE"))"
}

# ---------------------------------------------------------------------------
# STEP 1 — JDK 17+
# ---------------------------------------------------------------------------
if ! command -v java >/dev/null 2>&1; then
  log "ERROR: 'java' не найден. Нужен JDK 17+. Установка, напр.: brew install openjdk@17"
  emit "jdk_major: none"
  emit "status: error_no_jdk"
  emit "note: 'java' не найден. Нужен JDK 17+ (напр.: brew install openjdk@17)."
  write_baseline_report
  exit 3
fi
JVER="$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')"
if [[ -z "$JVER" || "$JVER" -lt 17 ]]; then
  log "ERROR: нужен JDK 17+, обнаружен '$JVER'. Установка, напр.: brew install openjdk@17"
  emit "jdk_major: ${JVER:-unknown}"
  emit "status: error_no_jdk"
  emit "note: обнаружен JDK '$JVER', нужен 17+."
  write_baseline_report
  exit 3
fi
log "JDK ok: $JVER"
emit "jdk_major: $JVER"

# ---------------------------------------------------------------------------
# STEP 2 — вендоренные бинарники
# ---------------------------------------------------------------------------
PMD_BIN="$(ls "$VENDOR"/pmd/*/bin/pmd 2>/dev/null | head -1 || true)"
CHECKSTYLE_JAR="$(ls "$VENDOR"/checkstyle/checkstyle-*-all.jar 2>/dev/null | head -1 || true)"
SPOTBUGS_BIN="$(ls "$VENDOR"/spotbugs/*/bin/spotbugs 2>/dev/null | head -1 || true)"

if [[ -z "$PMD_BIN" && -z "$CHECKSTYLE_JAR" ]]; then
  log "ERROR: не найдены вендоренные линтеры в $VENDOR"
  log "       Ожидались pmd/*/bin/pmd и checkstyle/checkstyle-*-all.jar."
  emit "status: error_no_linters"
  emit "note: не найдены вендоренные линтеры в $VENDOR (нужен vendoring/bootstrap)."
  write_baseline_report
  exit 4
fi

# #3 — сверка целостности вендоренных jar с checksums.sha256 (supply-chain).
CHECKSUMS="$VENDOR/checksums.sha256"
if [[ "$VERIFY" == "1" ]]; then
  if [[ -f "$CHECKSUMS" ]] && command -v shasum >/dev/null 2>&1; then
    if ( cd "$VENDOR" && shasum -a 256 -c "$CHECKSUMS" --status ) 2>/dev/null; then
      emit "integrity: ok"
    else
      emit "integrity: FAIL"
      log "⚠ ВНИМАНИЕ: вендоренные JAR не совпадают с checksums.sha256 — возможна подмена бинарников."
    fi
  else
    emit "integrity: skipped reason=no_checksums_or_shasum"
  fi
else
  emit "integrity: skipped reason=--no-verify"
fi

# ---------------------------------------------------------------------------
# STEP 3 — discovery src/main + src/test (рекурсивно, с исключениями)
# ---------------------------------------------------------------------------
# Портируемо (macOS bash 3.2 не имеет mapfile).
SRC_DIRS=()
while IFS= read -r _d; do
  [[ -n "$_d" ]] && SRC_DIRS+=("$_d")
done < <(
  find "$SCAN_ROOT" \
    \( -type d \( -name target -o -name build -o -name .git -o -name .gigacode \
                  -o -name node_modules -o -name linter-reports \) -prune \) \
    -o \( -type d \( -path '*/src/main' -o -path '*/src/test' \) -print \) \
  2>/dev/null | sort -u
)

# Число .java файлов (для summary) — тоже с исключениями.
JAVA_COUNT=0
if [[ ${#SRC_DIRS[@]} -gt 0 ]]; then
  JAVA_COUNT="$(find "${SRC_DIRS[@]}" -type f -name '*.java' 2>/dev/null | wc -l | tr -d ' ')"
fi

emit "java_file_count: $JAVA_COUNT"

if [[ ${#SRC_DIRS[@]} -eq 0 || "$JAVA_COUNT" -eq 0 ]]; then
  emit "status: no_java_found"
  emit "note: не найдены src/main или src/test с .java файлами под $SCAN_ROOT"
  log "Java-исходники не найдены — отчёт получит секцию 'Java не найдено'."
  write_baseline_report
  exit 0
fi

emit "status: ok"
for d in "${SRC_DIRS[@]}"; do emit "src_root: $d"; done

# Список исходных корней через запятую (для -d PMD/CPD).
SRC_CSV="$(IFS=,; echo "${SRC_DIRS[*]}")"

# #2 — детерминированные счётчики находок (из SARIF/XML, без участия LLM).
TOTAL_FINDINGS=0
HIGH_FINDINGS=0   # SARIF level=error (грубый High до нормализации субагентом)
count_re() { grep -oE "$2" "$1" 2>/dev/null | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------
# STEP 4 — PMD (SARIF)
# ---------------------------------------------------------------------------
if [[ -n "$PMD_BIN" ]]; then
  PMD_OUT="$TMP_DIR/pmd.sarif"
  log "PMD → $PMD_OUT"
  "$PMD_BIN" check \
      -d "$SRC_CSV" \
      -R "$RULESETS/pmd-smells.xml" \
      -f sarif \
      -r "$PMD_OUT" \
      --no-cache 2>"$TMP_DIR/pmd.log"
  rc=$?
  # PMD: 0 = чисто, 4 = найдены нарушения, иное = ошибка.
  if [[ "$rc" == "0" || "$rc" == "4" ]] && [[ -f "$PMD_OUT" ]]; then
    emit "linter: pmd status=ok file=$PMD_OUT"
    n=$(count_re "$PMD_OUT" '"ruleId"'); hi=$(count_re "$PMD_OUT" '"level": *"error"')
    emit "count: pmd=$n"
    TOTAL_FINDINGS=$((TOTAL_FINDINGS + n)); HIGH_FINDINGS=$((HIGH_FINDINGS + hi))
  else
    emit "linter: pmd status=error rc=$rc log=$TMP_DIR/pmd.log"
  fi
else
  emit "linter: pmd status=skipped reason=binary_not_vendored"
fi

# ---------------------------------------------------------------------------
# STEP 5 — Checkstyle (SARIF)
# ---------------------------------------------------------------------------
if [[ -n "$CHECKSTYLE_JAR" ]]; then
  CS_OUT="$TMP_DIR/checkstyle.sarif"
  log "Checkstyle → $CS_OUT"
  java -jar "$CHECKSTYLE_JAR" \
      -c "$RULESETS/checkstyle-smells.xml" \
      -f sarif \
      -o "$CS_OUT" \
      "${SRC_DIRS[@]}" 2>"$TMP_DIR/checkstyle.log"
  rc=$?
  # Checkstyle возвращает число нарушений как exit code (>0 при находках).
  if [[ -f "$CS_OUT" ]]; then
    emit "linter: checkstyle status=ok file=$CS_OUT"
    n=$(count_re "$CS_OUT" '"ruleId"'); hi=$(count_re "$CS_OUT" '"level": *"error"')
    emit "count: checkstyle=$n"
    TOTAL_FINDINGS=$((TOTAL_FINDINGS + n)); HIGH_FINDINGS=$((HIGH_FINDINGS + hi))
  else
    emit "linter: checkstyle status=error rc=$rc log=$TMP_DIR/checkstyle.log"
  fi
else
  emit "linter: checkstyle status=skipped reason=jar_not_vendored"
fi

# ---------------------------------------------------------------------------
# STEP 6 — PMD-CPD (XML; SARIF не поддерживается — субагент парсит XML)
# ---------------------------------------------------------------------------
if [[ -n "$PMD_BIN" ]]; then
  CPD_BIN="$(dirname "$PMD_BIN")/cpd"
  [[ -x "$CPD_BIN" ]] || CPD_BIN="$PMD_BIN"   # PMD7: cpd как отдельный бинарь; fallback
  CPD_OUT="$TMP_DIR/cpd.xml"
  log "CPD → $CPD_OUT (min-tokens=$MIN_TOKENS)"
  if [[ "$CPD_BIN" == *"/cpd" ]]; then
    "$CPD_BIN" --minimum-tokens "$MIN_TOKENS" --dir "$SRC_CSV" --format xml \
        --language java > "$CPD_OUT" 2>"$TMP_DIR/cpd.log"
  else
    "$PMD_BIN" cpd --minimum-tokens "$MIN_TOKENS" --dir "$SRC_CSV" --format xml \
        --language java > "$CPD_OUT" 2>"$TMP_DIR/cpd.log"
  fi
  rc=$?
  # CPD: 0 = нет дублей, 4 = дубли найдены, иное = ошибка.
  if [[ "$rc" == "0" || "$rc" == "4" ]] && [[ -s "$CPD_OUT" ]]; then
    emit "linter: cpd status=ok file=$CPD_OUT format=xml"
    n=$(count_re "$CPD_OUT" '<duplication'); emit "count: cpd=$n"
    TOTAL_FINDINGS=$((TOTAL_FINDINGS + n))
  else
    emit "linter: cpd status=error rc=$rc log=$TMP_DIR/cpd.log"
  fi
else
  emit "linter: cpd status=skipped reason=binary_not_vendored"
fi

# ---------------------------------------------------------------------------
# STEP 7 — SpotBugs (best-effort; требует скомпилированных классов, БЕЗ сборки)
# ---------------------------------------------------------------------------
# Детект Maven-проекта (для решения, можно ли собрать ради SpotBugs).
POM_FILE=""
if [[ -f "$SCAN_ROOT/pom.xml" ]]; then
  POM_FILE="$SCAN_ROOT/pom.xml"
else
  POM_FILE="$(find "$SCAN_ROOT" \( -name .git -o -name .gigacode -o -name node_modules \
                  -o -name target -o -name build \) -prune \
                -o -name pom.xml -print 2>/dev/null | sort | head -1)"
fi
MVN_AVAILABLE=0; command -v mvn >/dev/null 2>&1 && MVN_AVAILABLE=1
# Оркестратор читает это, чтобы решить — предлагать ли сборку пользователю.
emit "build_tool: maven pom=${POM_FILE:-none} mvn_available=$MVN_AVAILABLE"

discover_class_dirs() {
  CLASS_DIRS=()
  while IFS= read -r _c; do
    [[ -n "$_c" ]] && CLASS_DIRS+=("$_c")
  done < <(
    find "$SCAN_ROOT" \( -name .git -o -name .gigacode -o -name node_modules \) -prune \
      -o -type d \( -path '*/target/classes' -o -path '*/build/classes*' \) -print \
    2>/dev/null | sort -u
  )
}
discover_class_dirs

# Опциональная сборка ради SpotBugs (только с явного разрешения через флаг).
if [[ ${#CLASS_DIRS[@]} -eq 0 && "$BUILD_SPOTBUGS" == "1" ]]; then
  if [[ -n "$POM_FILE" && "$MVN_AVAILABLE" == "1" ]]; then
    log "mvn clean package -DskipTests=true (для SpotBugs)…"
    ( cd "$(dirname "$POM_FILE")" && mvn -q clean package -DskipTests=true ) \
        >"$TMP_DIR/mvn-build.log" 2>&1
    build_rc=$?
    emit "build: mvn rc=$build_rc log=$TMP_DIR/mvn-build.log"
    discover_class_dirs   # переоткрыть классы после сборки
  elif [[ -z "$POM_FILE" ]]; then
    emit "build: skipped reason=no_pom_xml"
  else
    emit "build: skipped reason=mvn_not_available"
  fi
fi

if [[ -n "$SPOTBUGS_BIN" && ${#CLASS_DIRS[@]} -gt 0 ]]; then
  SB_OUT="$TMP_DIR/spotbugs.sarif"
  log "SpotBugs → $SB_OUT (classes: ${#CLASS_DIRS[@]} dirs)"
  "$SPOTBUGS_BIN" -textui -low -sarif -output "$SB_OUT" \
      -sourcepath "$SRC_CSV" \
      "${CLASS_DIRS[@]}" 2>"$TMP_DIR/spotbugs.log"
  rc=$?
  if [[ -f "$SB_OUT" ]]; then
    emit "linter: spotbugs status=ok file=$SB_OUT"
    n=$(count_re "$SB_OUT" '"ruleId"'); hi=$(count_re "$SB_OUT" '"level": *"error"')
    emit "count: spotbugs=$n"
    TOTAL_FINDINGS=$((TOTAL_FINDINGS + n)); HIGH_FINDINGS=$((HIGH_FINDINGS + hi))
  else
    emit "linter: spotbugs status=error rc=$rc log=$TMP_DIR/spotbugs.log"
  fi
elif [[ -z "$SPOTBUGS_BIN" ]]; then
  emit "linter: spotbugs status=skipped reason=binary_not_vendored"
elif [[ "$BUILD_SPOTBUGS" == "1" ]]; then
  emit "linter: spotbugs status=skipped reason=build_failed_or_no_classes"
  emit "note: сборка не дала target/classes (см. mvn-build.log) — SpotBugs пропущен."
else
  emit "linter: spotbugs status=skipped reason=no_compiled_classes"
  emit "note: SpotBugs пропущен — не найдены target/classes|build/classes. Разреши сборку (mvn) для его запуска."
fi

[[ "$KEEP" == "1" ]] && emit "keep_tmp: true"

# #2 — итоговые детерминированные счётчики (сырые, до дедупликации субагентом).
emit "total_findings: $TOTAL_FINDINGS"
emit "high_findings: $HIGH_FINDINGS"

# #7 — CI-гейт: exit 5, если сработал --fail-on. Отчёт уже гарантирован ниже.
FINAL_EXIT=0
if [[ -n "$FAIL_ON" ]]; then
  case "$FAIL_ON" in
    any)          [[ "$TOTAL_FINDINGS" -gt 0 ]] && FINAL_EXIT=5 ;;
    high)         [[ "$HIGH_FINDINGS"  -gt 0 ]] && FINAL_EXIT=5 ;;
    ''|*[!0-9]*)  log "unknown --fail-on '$FAIL_ON' (ожидалось any|high|N)" ;;
    *)            [[ "$TOTAL_FINDINGS" -ge "$FAIL_ON" ]] && FINAL_EXIT=5 ;;
  esac
  emit "fail_on: spec=$FAIL_ON total=$TOTAL_FINDINGS high=$HIGH_FINDINGS exit=$FINAL_EXIT"
fi

# ГАРАНТИЯ: baseline-отчёт на диске (субагент позже перезапишет обогащённым).
write_baseline_report

log "done. manifest: $MANIFEST · report: $REPORT_FILE · findings: $TOTAL_FINDINGS (high $HIGH_FINDINGS)"
exit $FINAL_EXIT
