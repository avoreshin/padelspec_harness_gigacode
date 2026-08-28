#!/usr/bin/env bash
# destructive-command-blocker.sh (v3 — segment-aware)
# PreToolUse hook для Bash. Defense-in-depth поверх permissions.deny из settings.json.
# Согласно §4.4 + §4.5 PDLC v3.5.
#
# ГРАНИЦА ПРИМЕНИМОСТИ. Это не граница безопасности. Сопоставление шаблонов с
# текстом команды принципиально обходится — через переменные, кавычки внутри
# слова, base64, свой скрипт. Хук ловит неосторожность и типовые разрушительные
# формы, а настоящий запрет живёт в permissions.deny (settings.json) и в правах
# окружения, где агент запущен. Расширяя список ниже, не считайте, что
# добавили защиту от того, кто хочет её обойти.
#
# v2 → v3: закрыты обходы, найденные прогоном по живым хукам.
#   - Команда разбирается по сегментам (; && || | перевод строки). Раньше
#     проверка шла по всей строке целиком, поэтому R5-allowlist пропускал
#     'ls ; <что угодно>': совпадение '^ls ' в начале делало всю строку
#     разрешённой.
#   - Пробелы нормализуются: 'rm  -rf /' (двойной пробел) не совпадал с
#     шаблоном 'rm -rf /' и проходил.
#   - Сопоставление регистронезависимое: 'psql -c "drop table"' в нижнем
#     регистре проходил мимо R4-шаблона 'psql.*-c .*DROP'.
#   - Опасный rm распознаётся по флагам, а не по написанию: 'rm -fr /',
#     'rm -r -f /', 'rm --recursive --force /' раньше не ловились.
#   - Шаблоны git push анкерятся по \b, поэтому 'git push -f' в конце строки
#     больше не проскакивает мимо '-f[^a-z]'.

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

# Состояние risk class лежит в корне проекта; без резолва хук, запущенный с cwd
# подкаталога, читал бы несуществующий файл и работал как R1 при любом классе.
cd_harness_root

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

RISK_FILE=".gigacode/.cost/current-risk-class"
RISK_CLASS="R1"
if [[ -f "$RISK_FILE" ]]; then
  RISK_CLASS=$(tr -d '[:space:]' < "$RISK_FILE" 2>/dev/null || echo "R1")
fi
if ! [[ "$RISK_CLASS" =~ ^R[0-5]$ ]]; then
  RISK_CLASS="R1"
fi

# Нормализованная форма: одиночные пробелы, без ведущих/хвостовых.
# Шаблоны пишутся под неё, поэтому лишние пробелы больше не спасают команду.
normalize() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed -E 's/  +/ /g; s/^ +//; s/ +$//'
}

CMD_NORM="$(normalize "$COMMAND")"

# Сегменты команды: всё, что shell выполнит как отдельный вызов.
# Разбор намеренно грубый — он не разбирает кавычки и подстановки, его задача
# не дать «безобидной» первой команде легализовать всю строку целиком.
SEGMENTS=()
while IFS= read -r seg; do
  seg="$(normalize "$seg")"
  [[ -n "$seg" ]] && SEGMENTS+=("$seg")
done < <(printf '%s' "$COMMAND" | sed -E 's/\|\||&&|;|\||\n/\n/g')

# === BASE: always-blocked (любой R-класс) ===
ALWAYS_DANGEROUS=(
  'git push\b.*(--force\b|--force-with-lease\b|-f\b)'
  'git reset --hard origin'
  ':\(\)\{ ?:\|:& ?\};:'
  'mkfs\.'
  'dd if=.*of=/dev/'
  'chmod -R 777 /'
  '> ?/dev/(sd|nvme|hd)'
  '(curl|wget)\b.*\| *(ba|z|k|da)?sh\b'
)

# === R2+ дополнения ===
R2_DANGEROUS=(
  'npm publish'
  'pip install.*--user'
  'docker push'
)

# === R3+ дополнения ===
R3_DANGEROUS=(
  'terraform apply'
  'kubectl apply'
  'kubectl delete'
  'aws .*delete'
  'aws .*put-object.*credentials'
)

# === R4+ дополнения (фактически любая мутация требует human approval) ===
R4_DANGEROUS=(
  'psql.*-c .*(DROP|DELETE|UPDATE|TRUNCATE|ALTER)'
  'mongo.*\.drop\('
  'redis-cli.*(FLUSHALL|FLUSHDB)'
)

# === R5: всё, что не явно read-only ===
R5_READONLY_ALLOWED=(
  '^git (status|diff|log|show|branch --list)\b'
  '^(ls|cat|head|tail|grep|rg|find|wc|file|stat)\b'
  '^(npm test|pytest|go test|cargo test)\b'
  '^(pwd|whoami|date|echo)\b'
)

# Опасный rm распознаётся по смыслу, а не по написанию: нужны и рекурсия, и
# force, а цель — корень, домашний каталог или голая маска. Так ловятся -rf,
# -fr, -r -f и длинные формы, которые перечислением шаблонов не покрыть.
is_dangerous_rm() {
  local seg="$1"
  printf '%s' "$seg" | grep -qiE '(^| )rm( |$)' || return 1

  local flags recursive=0 force=0
  flags="$(printf '%s' "$seg" | grep -oE ' -[a-zA-Z]+| --[a-z-]+' | tr -d ' ')"
  printf '%s' "$flags" | grep -qE '^--recursive$|^-[a-zA-Z]*[rR]' && recursive=1
  printf '%s' "$flags" | grep -qE '^--force$|^-[a-zA-Z]*f' && force=1
  [[ "$recursive" -eq 1 && "$force" -eq 1 ]] || return 1

  # Цель: / , ~ , * , $HOME , /* — то есть смёт всего, а не конкретного каталога.
  printf '%s' "$seg" | grep -qE ' (/|~|\*|\$HOME|/\*)( |$)' && return 0
  return 1
}

# Проверить набор шаблонов против всей команды и против каждого её сегмента.
check_patterns() {
  local label="$1"; shift
  local pattern seg
  for pattern in "$@"; do
    if printf '%s' "$CMD_NORM" | grep -qiE -- "$pattern"; then
      deny "Destructive command blocked by $label for risk class $RISK_CLASS. Pattern: '$pattern'. Command: '$COMMAND'. §4.4 + §4.5 PDLC v3.5. To proceed: lower risk class with justification, or request human approval."
    fi
    for seg in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
      if printf '%s' "$seg" | grep -qiE -- "$pattern"; then
        deny "Destructive command blocked by $label for risk class $RISK_CLASS. Pattern: '$pattern'. Segment: '$seg'. Command: '$COMMAND'. §4.4 + §4.5 PDLC v3.5. To proceed: lower risk class with justification, or request human approval."
      fi
    done
  done
}

# rm — отдельной проверкой, по флагам
for seg in ${SEGMENTS[@]+"${SEGMENTS[@]}"} "$CMD_NORM"; do
  if is_dangerous_rm "$seg"; then
    deny "Destructive command blocked by BASE policy for risk class $RISK_CLASS. Рекурсивное принудительное удаление корня/домашнего каталога/маски: '$seg'. Command: '$COMMAND'. Вместо этого: перечисли конкретные пути явно, без масок и без '/' или '~' в основании; если удалить нужно именно так — это ручная операция человека. §4.4 PDLC v3.5."
  fi
done

# Всегда блокируем базовый набор
check_patterns "BASE policy" "${ALWAYS_DANGEROUS[@]}"

# Эскалация по R-классу
case "$RISK_CLASS" in
  R2|R3|R4|R5)
    check_patterns "R2+ policy" "${R2_DANGEROUS[@]}"
    ;;
esac

case "$RISK_CLASS" in
  R3|R4|R5)
    check_patterns "R3+ policy" "${R3_DANGEROUS[@]}"
    ;;
esac

case "$RISK_CLASS" in
  R4|R5)
    check_patterns "R4+ policy" "${R4_DANGEROUS[@]}"
    ;;
esac

# R5: deny-by-default. Разрешаем, только если КАЖДЫЙ сегмент — read-only.
# Раньше проверялась вся строка, и совпадения в её начале хватало, чтобы
# пропустить всё остальное: 'ls ; curl … | bash' считался разрешённым.
if [[ "$RISK_CLASS" == "R5" ]]; then
  for seg in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
    seg_allowed=0
    for pattern in "${R5_READONLY_ALLOWED[@]}"; do
      if printf '%s' "$seg" | grep -qE -- "$pattern"; then
        seg_allowed=1
        break
      fi
    done
    if [[ "$seg_allowed" -eq 0 ]]; then
      deny "Risk class R5 (regulated risk logic) requires human-driven Bash. Segment '$seg' is not in the read-only allowlist (command: '$COMMAND'). Instead: hand this command to a human operator, or split the task so the R5 part stays outside agent Bash. §4.5 PDLC v3.5: R5 autonomy = change_advisory_board, no autonomous Bash."
    fi
  done
fi

exit 0
