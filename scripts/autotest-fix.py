#!/usr/bin/env python3
"""autotest-fix.py — починка находок ревью автотестов.

Пятый шаг конвейера: `/review-autotests` называет расхождения между сценарием и
тест-моделью, этот скрипт чинит ту их часть, которая чинится **механически и без
выдумывания**.

Граница проходит по одному правилу, общему для всей обвязки: шаг не
изобретается. Починка либо подставляет значение из словаря `ParameterTypes`,
либо заменяет шаг на другой, уже существующий в инвентаре step definitions,
либо не делает ничего и оставляет находку человеку. Параметры нового шага
берутся из тест-модели и из переменных, определённых в самом сценарии или его
Предыстории; недостающий параметр — причина отказаться от починки, а не повод
придумать значение.

| Находка | Чинится | Чем |
|---|---|---|
| `polarity-drift` | да | значение ParameterType в том же шаге |
| `stand-mismatch`  | да | тег стенда из тест-модели |
| `object-missing`  | да, если однозначно | подстановка имени объекта в шаг |
| `channel-drift`   | да, если в инвентаре есть шаг нужного канала | замена шага |
| `no-assertion`    | да, на тех же условиях | дописывание шага-проверки |
| `step-uncovered`, `assertion-extra`, `precondition-missing`, `scenario-missing` | нет | это про содержание сценария, а не про его форму |

Использование:
  autotest-fix.py <release-key|path.yaml> [--project DIR] [--ids A,B] [--apply]

По умолчанию печатает план и **ничего не пишет**. Коды возврата:
  0 — чинить нечего либо всё запланированное применено
  1 — остались находки, которые механически не чинятся
  2 — ошибка вызова
"""

import argparse
import importlib.util
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с autotest-fix.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


review = _load("_pdls_review", "autotest-review.py")
corpus = review.corpus
exporter = review.exporter

# ---------------------------------------------------------------------------
# Словари починки
# ---------------------------------------------------------------------------
# Пары значений ParameterTypes, различающие «есть» и «нет». Инверсия полярности
# чинится подстановкой парного значения — новый шаг при этом не появляется.
POLARITY_PAIRS = (
    ("есть запись", "нет записи"),
    ("наличие", "отсутствие"),
    ("присутствует", "отсутствует"),
    ("появления", "удаления"),
)

STAND_TAGS = ("@st", "@ift", "@psi", "@nt")

# Маркеры канала, после которых в тексте ожидания стоит имя объекта.
OBJECT_AFTER = {
    "kafka": ("топике", "топик", "topic", "теме"),
    "ignite": ("cache", "кэше", "кеше", "cache"),
}

STASH_DEF_RE = re.compile(r'сохранить\s+.*?как\s+"([^"]+)"|сохраняет\s+.*?как\s+"([^"]+)"'
                          r'|как\s+"([^"]+)"')
PARAM_RE = re.compile(r"\{(\w+)\}")


def polarity_swap(text):
    """Заменяет значение полярности на парное. Возвращает None, если в шаге нет
    ни одного известного значения — тогда чинить нечем."""
    low = corpus.norm(text)
    for a, b in POLARITY_PAIRS:
        for src, dst in ((a, b), (b, a)):
            i = low.find(src)
            if i >= 0:
                return text[:i] + dst + text[i + len(src):]
    return None


def object_after_channel(expected, channel):
    """Имя объекта, стоящее сразу за маркером канала: «в топике AUDIT_LOG» →
    AUDIT_LOG. Не найдено — значит определить нельзя, и починки не будет."""
    markers = OBJECT_AFTER.get(channel, ())
    words = re.findall(r'"[^"]+"|[^\s,.;]+', expected)
    for i, w in enumerate(words[:-1]):
        if corpus.norm(w).strip('"') in markers:
            nxt = words[i + 1].strip('"')
            if len(nxt) >= 3:
                return nxt
    return None


def stash_vars(scenario):
    """Переменные, определённые в Предыстории файла и выше по сценарию."""
    out = []
    for step in list(scenario["background"]) + list(scenario["steps"]):
        for m in re.finditer(r'сохранить[^"]*как\s+"([^"]+)"|сохраняет[^"]*как\s+"([^"]+)"', step):
            for g in m.groups():
                if g and g not in out:
                    out.append(g)
    return out


def inventory(project):
    """Аннотации step definitions с их каналом."""
    out = []
    for path in corpus.find_stepdef_files(project):
        for st in corpus.parse_stepdefs(path):
            ann = st["annotation"]
            if ann.startswith("^") or "\\\\" in ann or "(?:" in ann:
                # regex-форма: подставить параметры в неё нельзя, не трогаем
                continue
            out.append({"annotation": ann,
                        "channel": review.primary_channel(ann),
                        "class": os.path.basename(path)})
    return out


def build_step(annotation, expected, channel, scenario):
    """Собирает строку шага из аннотации. Возвращает (шаг, None) либо
    (None, причина отказа) — параметр, который нечем заполнить."""
    obj = object_after_channel(expected, channel)
    if not obj:
        return None, "в ожидании не назван объект %s" % channel
    polarity = review.polarity_of(expected)
    vars_ = stash_vars(scenario)

    text = annotation
    used_object = False
    for name in PARAM_RE.findall(annotation):
        placeholder = "{%s}" % name
        if name in ("isRecord", "isExists", "isAppear"):
            value = None
            for a, b in POLARITY_PAIRS:
                if a in _param_values(name) or b in _param_values(name):
                    value = a if polarity != "negative" else b
                    break
            if value is None:
                return None, "не удалось выбрать значение для {%s}" % name
            text = text.replace(placeholder, value, 1)
        elif name == "string" and not used_object:
            text = text.replace(placeholder, '"%s"' % obj, 1)
            used_object = True
        elif name == "string":
            if len(vars_) != 1:
                return None, ("параметр {string} нечем заполнить: "
                              "переменных в сценарии %d" % len(vars_))
            text = text.replace(placeholder, '"#{%s}"' % vars_[0], 1)
        else:
            return None, "параметр {%s} не выводится из тест-модели" % name
    return "    * " + text, None


def _param_values(name):
    return {
        "isRecord": ("есть запись", "нет записи"),
        "isExists": ("наличие", "отсутствие"),
        "isAppear": ("появления", "удаления"),
    }.get(name, ())


# ---------------------------------------------------------------------------
# План починки
# ---------------------------------------------------------------------------
class Edit(object):
    def __init__(self, path, kind, cid, before, after, why):
        self.path, self.kind, self.cid = path, kind, cid
        self.before, self.after, self.why = before, after, why


def model_expectation(case, finding):
    """Ожидание того шага тест-модели, на который указывает находка."""
    steps = review.model_steps(case)
    m = re.match(r"шаг (\d+)", finding["text"])
    if m:
        i = int(m.group(1)) - 1
        if 0 <= i < len(steps):
            return steps[i].get("expected_result") or ""
    for st in steps:
        if st.get("expected_result"):
            return st["expected_result"]
    return ""


# Порядок разбора находок по одному сценарию. Он же приоритет: находки нижних
# классов часто описывают ту же строку, что и верхние («проверка ушла в лог» и
# «в этом шаге чужой литерал» — про один и тот же шаг). Разбор без порядка дал
# бы две правки на одну строку, вторая из которых портит первую.
FIX_ORDER = ("no-assertion", "channel-drift", "polarity-drift", "object-missing",
             "stand-mismatch")


def plan_case(case, scenario, findings, inv, project):
    edits, skipped, superseded = [], [], []
    cid = case["id"]
    path = os.path.join(project, scenario["path"])
    touched = set()
    assertion_added = False

    findings = sorted(findings, key=lambda f: FIX_ORDER.index(f["kind"])
                      if f["kind"] in FIX_ORDER else len(FIX_ORDER))

    for f in findings:
        kind = f["kind"]

        # Находка про уже переписанный шаг снимается вместе с ним. Это не
        # «починено» и не «остаётся человеку» — это следствие правки выше.
        if assertion_added and kind in ("channel-drift", "object-missing", "assertion-extra"):
            superseded.append(f)
            continue

        if kind == "stand-mismatch":
            stand = (case.get("stand") or "").strip()
            tags = [t for t in scenario["tags"] if t not in STAND_TAGS]
            pos = 0
            for i, t in enumerate(scenario["tags"]):
                if t.startswith("@gen-"):
                    pos = i + 2
            tags.insert(min(pos, len(tags)), stand)
            edits.append(Edit(path, kind, cid, " ".join(scenario["tags"]),
                              " ".join(tags), "стенд из тест-модели"))
            continue

        if kind == "polarity-drift":
            target = None
            for step in scenario["steps"]:
                if review.is_assertion(step) and polarity_swap(step):
                    target = step
                    break
            if target is None:
                skipped.append((f, "в шаге нет значения полярности из ParameterTypes"))
                continue
            if target.strip() in touched:
                superseded.append(f)
                continue
            touched.add(target.strip())
            edits.append(Edit(path, kind, cid, target, polarity_swap(target),
                              "парное значение ParameterType, шаг тот же"))
            continue

        if kind in ("channel-drift", "no-assertion"):
            expected = model_expectation(case, f)
            want = review.primary_channel(expected)
            if not want:
                skipped.append((f, "канал ожидания не определён"))
                continue
            cands = [s for s in inv if s["channel"] == want]
            built, reasons = [], []
            for c in cands:
                step, why = build_step(c["annotation"], expected, want, scenario)
                if step:
                    built.append((c, step))
                else:
                    reasons.append("%s — %s" % (c["annotation"], why))
            if not built:
                skipped.append((f, "в инвентаре нет шага канала «%s», который можно заполнить: %s"
                                % (review.channel_label(want), "; ".join(reasons[:2]) or "кандидатов нет")))
                continue
            if len(built) > 1:
                skipped.append((f, "в инвентаре %d подходящих шага канала «%s» — выбирает человек: %s"
                                % (len(built), review.channel_label(want),
                                   ", ".join(c["annotation"] for c, _ in built[:3]))))
                continue
            cand, step = built[0]
            if kind == "channel-drift":
                wrong = None
                for s in scenario["steps"]:
                    if review.is_assertion(s) and review.primary_channel(s) != want:
                        wrong = s
                        break
                if wrong is None:
                    skipped.append((f, "не нашёлся шаг-проверка чужого канала"))
                    continue
                if wrong.strip() in touched:
                    superseded.append(f)
                    continue
                touched.add(wrong.strip())
                edits.append(Edit(path, kind, cid, wrong, step.strip(),
                                  "шаг из инвентаря: %s" % cand["class"]))
            else:
                assertion_added = True
                edits.append(Edit(path, kind, cid, None, step,
                                  "дописан шаг из инвентаря: %s" % cand["class"]))
            continue

        if kind == "object-missing":
            m = re.search(r"«([^»]+)»", f["text"])
            name = m.group(1) if m else None
            # Подставлять можно только вместо литерала, которого в тест-модели
            # нет. Иначе починка меняет верное имя топика на другое имя из той
            # же модели — например, ставит статус на место топика, — и сценарий
            # начинает проверять несуществующий объект. Такая «починка» хуже
            # находки.
            model_names = set()
            for st in review.model_steps(case):
                model_names |= review.named_objects(st.get("description"))
                model_names |= review.named_objects(st.get("expected_result"))
            lower = {n.lower() for n in model_names}
            target, literals = None, []
            for s in scenario["steps"]:
                if not review.is_assertion(s):
                    continue
                lits = [q for q in review.QUOTED_RE.findall(s)
                        if not q.startswith("#{") and q.lower() not in lower]
                if len(lits) == 1:
                    target, literals = s, lits
                    break
            if not name or target is None:
                skipped.append((f, "в шаге-проверке нет ровно одного чужого литерала — "
                                   "подстановка неоднозначна либо не нужна"))
                continue
            if target.strip() in touched:
                superseded.append(f)
                continue
            touched.add(target.strip())
            edits.append(Edit(path, kind, cid, target,
                              target.replace('"%s"' % literals[0], '"%s"' % name, 1),
                              "имя объекта из тест-модели"))
            continue

        # Лишняя проверка на строке, которую заменила правка выше, — то же
        # следствие: сама строка уже не та.
        if kind == "assertion-extra" and (f.get("detail") or "").strip() in touched:
            superseded.append(f)
            continue

        skipped.append((f, "механически не чинится"))
    return edits, skipped, superseded


def apply_edits(edits, project):
    """Правки применяются по одному файлу за проход, по точному совпадению
    строки. Строка не найдена — правка пропускается: слепая запись по номеру
    строки после предыдущей правки уехала бы."""
    applied, failed = [], []
    by_file = {}
    for e in edits:
        by_file.setdefault(e.path, []).append(e)

    for path, items in by_file.items():
        lines = io.open(path, encoding="utf-8").read().split("\n")
        for e in items:
            if e.before is None:                      # дописать шаг в конец сценария
                idx = _scenario_end(lines, e.cid)
                if idx is None:
                    failed.append((e, "сценарий не найден в файле"))
                    continue
                lines.insert(idx, e.after)
                applied.append(e)
                continue
            hit = None
            for i, line in enumerate(lines):
                if line.strip() == e.before.strip():
                    hit = i
                    break
            if hit is None:
                failed.append((e, "строка не найдена — файл изменился"))
                continue
            indent = len(lines[hit]) - len(lines[hit].lstrip())
            lines[hit] = " " * indent + e.after.strip()
            applied.append(e)
        io.open(path, "w", encoding="utf-8").write("\n".join(lines))
    return applied, failed


def _scenario_end(lines, cid):
    """Индекс строки после последнего шага сценария с тегом @<cid>."""
    start = None
    for i, line in enumerate(lines):
        if ("@%s" % cid) in line:
            start = i
            break
    if start is None:
        return None
    end = None
    for i in range(start, len(lines)):
        stripped = lines[i].strip()
        if i > start and (stripped.startswith("@")
                          or corpus.starts_with_any(stripped, corpus.BLOCK_KEYWORDS["scenario"])
                          and i > start + 1):
            break
        if stripped and not stripped.startswith("#"):
            end = i
    return None if end is None else end + 1


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="ключ релиза ASFMSTD-NNNN либо путь к YAML")
    ap.add_argument("--project", default=".")
    ap.add_argument("--ids", default="")
    ap.add_argument("--apply", action="store_true", help="применить план")
    args = ap.parse_args()

    project = args.project
    if not os.path.isdir(project):
        die("каталог проекта не найден: %s" % project)

    model_path, model = review.load_model(args.target, project)
    cases = {c.get("id"): c for c in model["test_cases"] if isinstance(c, dict) and c.get("id")}
    index = review.find_scenarios(project)
    wanted = {i.strip() for i in args.ids.split(",") if i.strip()}
    inv = inventory(project)

    all_edits, all_skipped, all_superseded = [], [], []
    for cid, case in cases.items():
        if wanted and cid not in wanted:
            continue
        scenario = index.get(cid)
        if scenario is None:
            continue
        findings = review.review_case(case, scenario)
        if not findings:
            continue
        edits, skipped, superseded = plan_case(case, scenario, findings, inv, project)
        all_edits.extend(edits)
        all_skipped.extend(skipped)
        all_superseded.extend(superseded)

    print("## Autotest Fix")
    print("")
    print("Тест-модель: %s" % os.path.relpath(model_path, project).replace("\\", "/"))
    print("Инвентарь шагов: %d (regex-формы пропущены — в них не подставить параметры)"
          % len(inv))
    print("")

    if not all_edits and not all_skipped:
        print("Находок нет — чинить нечего.")
        return 0

    print("Чинится: %d" % len(all_edits))
    for e in all_edits:
        print("  [%s] %s" % (e.kind, e.cid))
        if e.before is not None:
            print("    было:  %s" % e.before.strip())
        print("    стало: %s" % e.after.strip())
        print("    почему: %s" % e.why)
    print("")

    if all_superseded:
        print("Снимется вместе с правкой выше: %d" % len(all_superseded))
        for f in all_superseded:
            print("  [%s] %s" % (f["kind"], f["id"]))
        print("")

    if all_skipped:
        print("Остаётся человеку: %d" % len(all_skipped))
        for f, why in all_skipped:
            print("  [%s] %s — %s" % (f["kind"], f["id"], f["text"]))
            print("    %s" % why)
        print("")

    if not args.apply:
        print("Ничего не записано. Применить: --apply")
        # План — это незавершённая работа: правки не применены. Ноль здесь
        # читался бы вызывающим как «чинить нечего».
        return 1

    applied, failed = apply_edits(all_edits, project)
    print("Применено: %d" % len(applied))
    for e, why in failed:
        print("  ✗ [%s] %s — %s" % (e.kind, e.cid, why))
    print("")
    print("Проверить: git diff · перепрогнать ревью: autotest-review.py %s --project %s"
          % (args.target, project))
    return 1 if (all_skipped or failed) else 0


if __name__ == "__main__":
    sys.exit(main())
