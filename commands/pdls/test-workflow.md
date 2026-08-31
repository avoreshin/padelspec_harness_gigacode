---
description: Оркестратор цикла тестирования — ведёт релиз через фазы profile → model → autotests → review → run → export, пишет переходы в audit-трейл и собирает свод по релизу. Отдельные команды при этом продолжают работать сами по себе
---

Проведи релиз через цикл тестирования: {{args}} (ключ релиза `ASFMSTD-NNNN`; флаг `--resume` — продолжить с последней записанной фазы).

**Тип задачи:** цикл тестировщика. **R1** до фазы `run`, **R2** дальше: прогон трогает общий стенд, а выгрузка готовит файл для внешней системы.

```
<EMIT>      ${extensionPath}/scripts/emit-phase-event.sh --loop testing
<STATE>     ${extensionPath}/scripts/workflow-state.sh
<EVIDENCE>  ${extensionPath}/scripts/collect-test-evidence.py
```

## Это не dev-цикл под другим именем

| | dev-цикл | цикл тестирования |
|---|---|---|
| Acceptance criteria | SDD в `docs/sdd/` | тест-модель `docs/testcases/<release>.yaml` |
| Продукт фазы | код | сценарии в feature-файлах |
| «Тесты неприкосновенны» | да, гейт `test-files-protector` | **неприменимо** — тесты и есть продукт |
| Ревью | код против SDD | сценарии против тест-модели |
| Доказательство | evidence bundle | свод по релизу (`<release>.evidence.json`) |

Поэтому у него свой словарь фаз, и переходы пишутся с `--loop testing`. Событие dev-цикла остаётся ровно таким, каким было, — иначе всё, что уже читает трейл, читало бы новый формат.

## Фазы

| Фаза | Команда | Что фиксируется |
|---|---|---|
| `profile` | `/pdls:test-project` | чем написан проект, где тесты, чем запускается |
| `model` | `/pdls:generate-test-cases <release>` | тест-модель — acceptance criteria релиза |
| `autotests` | `/pdls:generate-autotests <release>` | сценарии в feature-файлах |
| `review` | `/pdls:review-autotests <release> --fix` | вердикт сверки с тест-моделью |
| `run` | `/pdls:test-run <release>` | прогон по тегам `@gen-*` |
| `export` | `/pdls:export-testcases-xml <release>` | XML для загрузки человеком |

## Процесс

1. Разобрать ключ релиза. Пусто — спросить.
2. `bash <STATE> <release>` — есть ли уже состояние. Есть и задан `--resume` — продолжить с `next_recommended_command`; есть без `--resume` — показать состояние и спросить, продолжать или начать заново.
3. Напечатать план и **спросить подтверждение** (`AskUserQuestion`) до первого шага.
4. Для каждой фазы: вызвать её команду, дождаться результата, записать переход:

```bash
bash <EMIT> <release> <from> <to> <status> <iteration> "<причина>"
```

   `status`: `pass` — фаза дала результат; `iterate` — повтор той же фазы; `fail` — откат на предыдущую; `escalate` — нужен человек.

5. **Между фазами не продолжать молча.** До `run` — авто-переход при `pass`, дальше (R2) — подтверждение на каждом шаге.
6. После `export` — собрать свод: `python3 <EVIDENCE> <release> --run-status <...> --export-file <...>` и записать переход `export → done`.

## Откаты

Возврат не в «начало», а туда, где лежит причина:

| Что случилось | Куда | Почему |
|---|---|---|
| ревью: `channel-drift`, `polarity-drift`, `no-assertion` | `autotests` | форма сценария, чинится генерацией и `--fix` |
| ревью: `step-uncovered`, ожидание сформулировано общо | `model` | правит человек: это про содержание проверки |
| ревью: `scenario-missing` | `autotests` | сценарий не был записан |
| прогон: `fix` | `autotests` | шаг не сматчился |
| прогон: `out-of-scope` | **останов, `escalate`** | дефект продукта либо неверное ожидание; подгонять сценарий запрещено |
| прогон: `infra` | останов | прогона не было, чинить окружение |

Потолок — **3 итерации** на фазу. Исчерпан — `escalate` и останов с журналом.

## Отдельные команды продолжают работать

Оркестратор — надстройка. Переходы пишет он, а не команды: `/pdls:generate-autotests`, вызванная руками, ведёт себя ровно как раньше — ничего не пишет в трейл и ничего не требует. Гейт `autotest-review-gate` работает одинаково в обоих режимах: он пересчитывает сверку по файлам, а не смотрит на состояние цикла.

## Output (в чат)

```
## Test Workflow — ASFMSTD-8441
  Фазы:    profile → model → autotests → review → run → export
  Режим:   авто до run, подтверждение дальше
  Потолок: 3 итерации на фазу

✅ profile    pass   cucumber-jvm / maven, инвентарь 312 шагов
✅ model      pass   11 кейсов, 3 отброшено
✅ autotests  pass   9 сценариев в 2 файлах
🔁 review     iterate  BLOCK → починено 5 → REQUEST CHANGES
✅ review     pass   остались 2 major — в своде
⏸️ run        escalate  out-of-scope: expected APPROVED but was DECLINED

⏹️ Останов на фазе run. Сценарий доехал до проверки, сообщение ушло —
   дальше дефект продукта либо ожидание в тест-модели. Не зона обвязки.
   Состояние: bash ${extensionPath}/scripts/workflow-state.sh ASFMSTD-8441
   Продолжить: /pdls:test-workflow ASFMSTD-8441 --resume
```

## Next step

Цикл закрыт сводом `<release>.evidence.json`. **Коммит команда не делает** — ни тест-модель, ни сценарии, ни свод.
