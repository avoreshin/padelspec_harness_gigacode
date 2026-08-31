#!/usr/bin/env bash
# collect-evidence.sh
# Собирает deterministic-часть evidence bundle и кладёт черновик в
# .gigacode/evidence-bundle.draft.json. Модель потом дозаполняет semantic-поля
# (acceptance_criteria_status, open_assumptions, security_verdict для R3+)
# и сохраняет финальный bundle в .gigacode/evidence-bundle.json.
#
# Стратегия: всё что можно достать из git/файловой системы — достаём здесь,
# чтобы модель не врала. AC mapping и assumptions нельзя — это требует
# понимания, что было сделано.

set -euo pipefail

OUTPUT="${1:-.gigacode/evidence-bundle.draft.json}"
SDD_DIR="${SDD_DIR:-docs/sdd}"

# === git context ===
in_git=false
DIRTY=false
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  in_git=true
  # `|| echo` здесь недостаточно: в репозитории без коммитов rev-parse печатает
  # "HEAD" в stdout И возвращает ненулевой код, поэтому BRANCH становился
  # двухстрочным "HEAD\nunknown" — и в git_context.branch, и в task_id.
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=""
  [[ -n "$BRANCH" ]] || BRANCH="unknown"
  HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then DIRTY=true; fi
else
  BRANCH="not-a-git-repo"
  HEAD_SHA=""
fi

# === diff_summary ===
files_changed=0
additions=0
deletions=0
files_json="[]"

if [[ "$in_git" == "true" ]]; then
  # Disable pipefail locally — grep-with-no-match is expected on a clean repo.
  set +o pipefail

  # Combine staged, unstaged and untracked into one deduplicated stream.
  # Exclude the bundle output paths themselves — they're harness artefacts,
  # not the work being audited.
  bundle_final="${OUTPUT%.draft.json}.json"
  [[ "$bundle_final" == "$OUTPUT" ]] && bundle_final="${OUTPUT%.json}.json"
  tmp_changed=$(mktemp)
  # Файл не удалялся ни на одной ветке: каждый прогон /evidence оставлял мусор
  # в $TMPDIR. trap — потому что между созданием и удалением есть git-вызовы.
  trap 'rm -f "$tmp_changed"' EXIT
  {
    git diff --cached --name-only 2>/dev/null || true
    git diff --name-only 2>/dev/null || true
    git ls-files --others --exclude-standard 2>/dev/null || true
  } | sort -u | sed '/^$/d' \
    | grep -vxF "$OUTPUT" \
    | grep -vxF "$bundle_final" \
    > "$tmp_changed" || true
  changed_files=$(cat "$tmp_changed")
  files_changed=$(wc -l < "$tmp_changed" | tr -d ' ')

  # Line stats for tracked changes (staged + unstaged combined).
  stats=$( { git diff --numstat --cached 2>/dev/null; git diff --numstat 2>/dev/null; } )
  additions=$(echo "$stats" | awk '$1 ~ /^[0-9]+$/ { sum += $1 } END { print sum+0 }')
  deletions=$(echo "$stats" | awk '$2 ~ /^[0-9]+$/ { sum += $2 } END { print sum+0 }')

  set -o pipefail

  # Build files[] array with change_type per file.
  if [[ "$files_changed" -gt 0 ]]; then
    files_json=$(
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
          # Tracked: check if staged-add, modified, deleted
          if git diff --cached --name-only --diff-filter=A | grep -qxF "$f"; then
            t="added"
          elif [[ ! -f "$f" ]]; then
            t="deleted"
          else
            t="modified"
          fi
        else
          t="added"
        fi
        printf '%s\n' "{\"path\":\"$f\",\"change_type\":\"$t\"}"
      done <<<"$changed_files" | jq -s '.'
    )
  fi
fi

# === sdd_reference: auto-detect most recently modified SDD ===
sdd_ref=""
risk_class=""
task_id=""
if [[ -d "$SDD_DIR" ]]; then
  newest_sdd=$(find "$SDD_DIR" -maxdepth 2 -name "*.md" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1 || true)
  if [[ -n "$newest_sdd" ]]; then
    sdd_ref="$newest_sdd"
    # Try to extract risk_class from SDD frontmatter (markdown table | **Risk class** | R<N> |)
    risk_class=$(awk -F'|' '
      /\*\*Risk class\*\*/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        if (match($3, /R[0-5]/)) print substr($3, RSTART, RLENGTH)
        exit
      }' "$newest_sdd" 2>/dev/null)
    # Try to extract ID from SDD frontmatter (| **ID** | SDD-... |)
    task_id=$(awk -F'|' '
      /\*\*ID\*\*/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $3)
        print $3
        exit
      }' "$newest_sdd" 2>/dev/null)
  fi
fi

# === risk_class fallback: рантайм-состояние ===
# .gigacode/.cost/current-risk-class — то, что пишет /risk-classify и читают
# cost-circuit-breaker и destructive-command-blocker, то есть класс, под которым
# сессия фактически шла. Раньше collect-evidence смотрел только в таблицу SDD:
# при заполненном /risk-classify, но без строки «Risk class» в спеке bundle
# получал risk_class=FILL_ME_IN, и evidence-bundle-enforcer его отвергал.
# Приоритет у SDD — это спецификация; рантайм-файл закрывает пробел и заодно
# показывает расхождение, если оно есть.
RUNTIME_RISK=""
if [[ -f ".gigacode/.cost/current-risk-class" ]]; then
  RUNTIME_RISK=$(tr -d '[:space:]' < .gigacode/.cost/current-risk-class 2>/dev/null)
  [[ "$RUNTIME_RISK" =~ ^R[0-5]$ ]] || RUNTIME_RISK=""
fi
if [[ -z "$risk_class" && -n "$RUNTIME_RISK" ]]; then
  risk_class="$RUNTIME_RISK"
elif [[ -n "$risk_class" && -n "$RUNTIME_RISK" && "$risk_class" != "$RUNTIME_RISK" ]]; then
  echo "[collect-evidence] ВНИМАНИЕ: в SDD risk class $risk_class, а гейты работали под $RUNTIME_RISK. В bundle идёт $risk_class — проверь, какой верен." >&2
fi

# === task_id fallback: branch name → JIRA-style key ===
if [[ -z "$task_id" && "$in_git" == "true" ]]; then
  if [[ "$BRANCH" =~ ([A-Z]+-[0-9]+) ]]; then
    task_id="${BASH_REMATCH[1]}"
  else
    task_id="$BRANCH"
  fi
fi

# === test framework detection (hint only, doesn't run anything) ===
test_framework="unknown"
test_command="unknown"
if [[ -f package.json ]]; then
  if jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    test_command="npm test"
    if grep -q '"vitest"' package.json; then test_framework="vitest"
    elif grep -q '"jest"' package.json; then test_framework="jest"
    elif grep -q '"mocha"' package.json; then test_framework="mocha"
    else test_framework="node:test"; fi
  fi
elif [[ -f pyproject.toml || -f pytest.ini || -f setup.cfg ]]; then
  test_framework="pytest"
  test_command="pytest"
elif [[ -f Cargo.toml ]]; then
  test_framework="cargo"
  test_command="cargo test"
elif [[ -f go.mod ]]; then
  test_framework="go"
  test_command="go test ./..."
fi

# === assemble draft ===
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg task_id "${task_id:-FILL_ME_IN}" \
  --arg risk_class "${risk_class:-FILL_ME_IN}" \
  --arg sdd_ref "${sdd_ref:-FILL_ME_IN}" \
  --arg branch "$BRANCH" \
  --arg head_sha "$HEAD_SHA" \
  --argjson dirty "$DIRTY" \
  --argjson files_changed "$files_changed" \
  --argjson additions "$additions" \
  --argjson deletions "$deletions" \
  --argjson files "$files_json" \
  --arg test_framework "$test_framework" \
  --arg test_command "$test_command" \
  --arg completed_at "$completed_at" \
  '{
    schema_version: "3.5.0",
    task_id: $task_id,
    risk_class: $risk_class,
    sdd_reference: $sdd_ref,
    git_context: {
      branch: $branch,
      head_sha: $head_sha,
      dirty: $dirty
    },
    diff_summary: {
      files_changed: $files_changed,
      additions: $additions,
      deletions: $deletions,
      files: $files
    },
    test_hint: {
      framework: $test_framework,
      command: $test_command,
      note: "Run this command and fill the tests block manually. Auto-detection of pass/fail counts is per-runner and lives outside this script."
    },
    tests: {
      status: "FILL_ME_IN — must be passed|failed|skipped|unknown",
      passed: 0,
      failed: 0,
      skipped: 0
    },
    acceptance_criteria_status: [
      "FILL_ME_IN — array of { id, status, test_reference }"
    ],
    open_assumptions: [
      "FILL_ME_IN — array of strings; empty array if none"
    ],
    commands_run: [
      "FILL_ME_IN — list of build/test/lint commands you actually ran"
    ],
    completed_at: $completed_at
  }' > "$OUTPUT"

echo "[collect-evidence] draft written to $OUTPUT" >&2
echo "[collect-evidence] auto-filled: git_context, diff_summary, completed_at, sdd_reference=$sdd_ref, risk_class=$risk_class, task_id=$task_id" >&2
echo "[collect-evidence] FILL_ME_IN fields: tests, acceptance_criteria_status, open_assumptions, commands_run" >&2
