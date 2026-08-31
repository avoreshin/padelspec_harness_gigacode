#!/usr/bin/env bash
# implement-iteration-cap-gate.sh — PreToolUse hook for Bash.
#
# README: «Hooks как enforcement. Модель проигнорировать может — хук нет.»
# implement.md документирует iteration cap («Iteration cap: 3. На 4-й попытке —
# mandatory escalation», GIGACODE.md §9), но до этого хука cap держался только на
# инструкции: модель сама читала iteration через workflow-state.sh, сама считала
# и сама решала остановиться. Хук делает cap детерминированным в единственной
# точке, где итерация фиксируется durable — emit-phase-event.sh («единственный
# писатель событий phase_transition», см. шапку того скрипта).
#
# Contract:
#   - stdin: JSON event with .tool_input.command
#   - acts only on Bash commands invoking `emit-phase-event.sh`; everything
#     else → exit 0 (noop)
#   - args per emit-phase-event.sh: <task-id> <from> <to> <status> <iteration> [reason]
#   - blocks iff: <to>=implement AND <status> ∈ {pass,iterate} AND <iteration> >= 4
#     (при iteration>=4 единственный легальный status — escalate, implement.md §7/§10)
#   - cap намеренно scoped на <to>=implement: у plan/test/review/evidence
#     задокументированного кэпа нет
#   - unparsable args → exit 0 (не блокируем неоднозначное; false block дороже
#     пропущенного гейта — та же позиция, что в commit-message-format.sh)
#   - violation → {"decision":"block","reason":…} + exit 2
#
# Scope: гейт стоит на ЗАПИСИ 4-й попытки, а не на самой 4-й правке кода —
# обобщённый PreToolUse-хук не может надёжно связать произвольный Edit/Write
# с конкретной задачей и итерацией. То же принятое ограничение, что у
# sdd-schema-gate.sh (валидация в момент записи, не раньше).

source "${BASH_SOURCE[0]%/*}/lib/common.sh" || exit 2

hook_read_payload

COMMAND="$(hook_field '.tool_input.command')"
[ -z "$COMMAND" ] && exit 0

# Only care about calls that invoke emit-phase-event.sh.
printf '%s' "$COMMAND" | grep -qE 'emit-phase-event\.sh' || exit 0

# Everything after the script name is the positional arg list per the contract.
ARGS_STR="$(printf '%s' "$COMMAND" | sed -nE 's/.*emit-phase-event\.sh[[:space:]]+(.*)/\1/p')"
[ -z "$ARGS_STR" ] && exit 0

# Split on whitespace into positionals. Globbing off — a stray * in <reason>
# must not expand against the working directory.
set -f
# shellcheck disable=SC2086
set -- $ARGS_STR
set +f

TO="${3:-}"
STATUS="${4:-}"
ITERATION="${5:-}"

# Cap is implement-phase-only (GIGACODE.md §9, implement.md).
[ "$TO" = "implement" ] || exit 0

# escalate — это и есть корректный выход при исчерпанном кэпе; fail ретраится
# на месте (implement.md §7). Гейт касается только pass/iterate.
case "$STATUS" in
  pass|iterate) ;;
  *) exit 0 ;;
esac

# Не целое — пусть ругается собственная валидация emit-phase-event.sh.
case "$ITERATION" in
  ''|*[!0-9]*) exit 0 ;;
esac

if [ "$ITERATION" -ge 4 ]; then
  block "iteration cap: попытка записать <to>=implement <status>=$STATUS <iteration>=$ITERATION. implement.md: 'Iteration cap: 3. На 4-й попытке — mandatory escalation.' При iteration >= 4 единственный допустимый <status> — 'escalate' (next_phase=plan, mandatory rollback на /sdd-new, implement.md §7/§10). Пересчитай итерацию через 'bash .gigacode/scripts/workflow-state.sh <task-id>' или исправь вызов на status=escalate."
fi

exit 0
