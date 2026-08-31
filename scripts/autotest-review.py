#!/usr/bin/env python3
"""autotest-review.py — сверка сгенерированных сценариев с тест-моделью.

Четвёртый шаг конвейера тестировщика и прямой аналог фазы review в PDLC-loop'е:
там сгенерированный код сверяется с SDD и acceptance criteria, здесь —
сгенерированный сценарий с тест-моделью `docs/testcases/<release>.yaml`,
которая для автотеста и есть acceptance criteria.

Зачем отдельный шаг. Проверки генератора структурные: шаг существует в
инвентаре, имя атрибута встречалось, stash-переменная определена, тип совпал.
Все они проходят на сценарии, который проверяет **не то**: тест-модель просит
проверить запись в топике Kafka, а сценарий читает лог на машине. Шаг найден,
синтаксис верен, dry-run зелёный, смысл потерян. Ловится это только сверкой
намерения с реализацией — и делать её должен не тот, кто генерировал.

Скрипт делает механическую часть: разбирает канал проверки, полярность и
именованные объекты по обе стороны и печатает расхождения. Смысловую часть —
то, что из текста не выводится, — добирает скилл autotest-review.

Использование:
  autotest-review.py <release-key|path.yaml> [--project DIR] [--ids A,B] [--json]

Коды возврата:
  0 — APPROVE: ни blocker'ов, ни major
  1 — REQUEST CHANGES / BLOCK: есть находки
  2 — ошибка вызова, тест-модель не разобрана либо проект не похож на проект
      автотестов
"""

import argparse
import importlib.util
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    """Соседний скрипт как модуль: разбор Gherkin и YAML уже написан, второй
    экземпляр каждого разошёлся бы с первым молча."""
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с autotest-review.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


corpus = _load("_pdls_corpus", "autotest-corpus.py")
exporter = _load("_pdls_export", "export-testcases-xml.py")

# ---------------------------------------------------------------------------
# Словари разбора. Всё, что зависит от предметной области, живёт здесь.
# ---------------------------------------------------------------------------
# Канал проверки — где именно проверяется результат. Порядок = приоритет:
# «проверить лог в топике Kafka» — это kafka, а не file, потому что kafka выше.
# Обратный порядок дал бы ровно ту ошибку, ради которой написан этот скрипт.
CHANNELS = (
    ("kafka",  "топик Kafka",        ("топик", "topic", "kafka", "кафк")),
    ("ignite", "IGNITE Cache",       ("ignite", "игнайт", "cache", "кэш", "кеш")),
    ("db",     "база данных",        ("таблиц", "базе данных", "субд", "select ", "postgres", "oracle", " бд ")),
    ("rest",   "REST/АРМ",           ("rest", "http", "endpoint", "апи", "api", "арм", "back")),
    ("ui",     "интерфейс",          ("браузер", "страниц", "веб-интерфейс", " ui ")),
    ("file",   "лог/файл на машине", ("логе", "лог ", "логи", "log", "файл", "консол", "stdout", "машине", "сервере", "ssh", "команд")),
)

# Полярность ожидания. Отрицание проверяется первым: «не содержит» содержит
# «содерж», и обратный порядок читал бы отрицание как утверждение.
NEGATIVE = ("отсутств", "нет запис", "не должн", "не появ", "не содерж", "нет ключа",
            "не пришл", "не сработ", "не создан", "не изменил", "без запис")
POSITIVE = ("наличие", "есть запис", "должн", "появ", "содерж", "присутств",
            "пришл", "сработ", "создан", "равно", "ушёл", "ушел")

# Глаголы проверки: по ним видно, что в сценарии есть шаг-проверка, а не только
# шаги подготовки и действия.
ASSERT_WORDS = ("провер", "убедит", "сверит", "ожидает", "должен", "должна", "должно")

# Служебные шаги: они есть в сценарии всегда и в тест-модели не описываются.
# Попадание их в «лишние шаги» превратило бы отчёт в шум.
UTILITY_STEPS = ("сгенерировать", "сохранить", "сохраняет", "ждем", "ждём", "подготовить",
                 "очистить", "установить соединение", "вычислить время")

QUOTED_RE = re.compile(r'"([^"]*)"')
STASH_RE = re.compile(r'#\{[^}]*\}')
UPPER_TOKEN_RE = re.compile(r'\b[A-Z][A-Z0-9_]{2,}\b')

SEVERITIES = ("blocker", "major", "minor")


def norm(text):
    return corpus.norm(text or "")


def channels_of(text):
    """Множество каналов, упомянутых в тексте. Пусто — канал не назван."""
    t = " %s " % norm(text)
    found = []
    for key, _label, markers in CHANNELS:
        if any(m in t for m in markers):
            found.append(key)
    return found


def primary_channel(text):
    """Канал по приоритету: первый из CHANNELS, который нашёлся."""
    found = channels_of(text)
    for key, _label, _m in CHANNELS:
        if key in found:
            return key
    return None


def channel_label(key):
    for k, label, _m in CHANNELS:
        if k == key:
            return label
    return key


def polarity_of(text):
    t = norm(text)
    for m in NEGATIVE:
        if m in t:
            return "negative"
    for m in POSITIVE:
        if m in t:
            return "positive"
    return None


def named_objects(text):
    """Имена, которые обязаны совпасть по обе стороны: строки в кавычках и
    UPPER_SNAKE-идентификаторы (топики, кэши, домены). Stash-переменные
    выбрасываются — их имена свои у каждого сценария."""
    if not text:
        return set()
    out = set()
    body = STASH_RE.sub(" ", text)
    for q in QUOTED_RE.findall(body):
        q = q.strip()
        if q and not q.startswith("#{"):
            out.add(q)
    for u in UPPER_TOKEN_RE.findall(body):
        out.add(u)
    return {o for o in out if len(o) >= 3}


def is_assertion(text):
    t = norm(text)
    return any(w in t for w in ASSERT_WORDS)


def is_utility(text):
    t = norm(text)
    body = t.split(" ", 1)[1] if " " in t else t
    return any(body.startswith(u) or (" %s " % u) in (" %s " % body) for u in UTILITY_STEPS)


def token_overlap(a, b):
    """Доля значимых слов a, нашедших пару в b. Стем — общий с корпусом."""
    at, bt = corpus.tokens(a), corpus.tokens(b)
    if not at:
        return 0.0
    hits = sum(1 for w in at if corpus.any_match(w, bt))
    return float(hits) / len(at)


# ---------------------------------------------------------------------------
# Чтение сторон сверки
# ---------------------------------------------------------------------------
def load_model(target, project):
    path = target
    if not path.endswith((".yaml", ".yml")):
        path = os.path.join(project, "docs", "testcases", "%s.yaml" % target)
    if not os.path.isfile(path):
        die("тест-модель не найдена: %s" % path)
    data = exporter.load_yaml(path)
    if not isinstance(data, dict) or not data.get("test_cases"):
        die("в тест-модели нет непустого test_cases: %s" % path)
    return path, data


def scenario_body(path, start_line):
    """Сырой текст сценария от его строки до следующего блока, без комментариев.

    Комментарии исключены намеренно: генератор переносит намерение шага из
    тест-модели комментарием перед шагом, и сверка вместе с ними всегда была бы
    зелёной — сравнивали бы тест-модель с её же копией, а не с шагами.
    """
    lines = io.open(path, encoding="utf-8", errors="replace").read().split("\n")
    out = []
    started = False
    for i, raw in enumerate(lines, start=1):
        line = raw.strip()
        if i < start_line:
            continue
        if i == start_line:
            started = True
            continue
        if not started:
            continue
        if line.startswith("@") or corpus.starts_with_any(line, corpus.BLOCK_KEYWORDS["scenario"]):
            break
        if line.startswith("#"):
            continue
        out.append(line)
    return [l for l in out if l]


def find_scenarios(project):
    """→ {тег @gen-*: {path, module, name, tags, steps, body, background}}"""
    index = {}
    for path in corpus.find_feature_files(project):
        data = corpus.parse_feature(path)
        module = corpus.module_of(project, path)
        for sc in data["scenarios"]:
            gen_tags = [t for t in sc["tags"] if t.startswith("@gen-")]
            if not gen_tags:
                continue
            body = scenario_body(path, sc["line"])
            for t in gen_tags:
                index[t[1:]] = {
                    "path": os.path.relpath(path, project).replace("\\", "/"),
                    "module": module,
                    "name": sc["name"],
                    "tags": sc["tags"],
                    "steps": sc["steps"],
                    "body": body,
                    "background": data["background"],
                }
    return index


# ---------------------------------------------------------------------------
# Правила сверки
# ---------------------------------------------------------------------------
def model_steps(case):
    script = case.get("script") or {}
    steps = script.get("steps") or []
    return [s for s in steps if isinstance(s, dict)]


def review_case(case, scenario):
    """→ список находок по одному сценарию."""
    findings = []
    cid = case.get("id") or "(без id)"

    def add(sev, kind, text, detail=""):
        findings.append({"severity": sev, "kind": kind, "id": cid,
                         "text": text, "detail": detail})

    steps = scenario["steps"]
    actual_all = " \n ".join(steps + scenario["body"])
    actual_channels = set()
    for s in steps + scenario["body"]:
        actual_channels.update(channels_of(s))

    # 1. Канал проверки. Главная находка: проверка ушла не туда.
    for n, st in enumerate(model_steps(case), start=1):
        expected = st.get("expected_result") or ""
        want = primary_channel(expected)
        if not want:
            continue
        if want in actual_channels:
            continue
        got = sorted({c for c in actual_channels if c != want})
        add("blocker", "channel-drift",
            "шаг %d: проверка ожидалась в «%s», в сценарии её там нет" % (n, channel_label(want)),
            "ожидание: %s\n  в сценарии проверка идёт через: %s"
            % (expected.strip(), ", ".join(channel_label(g) for g in got) or "канал не определён"))

    # 2. Полярность: «отсутствует» превратилось в «присутствует».
    for n, st in enumerate(model_steps(case), start=1):
        expected = st.get("expected_result") or ""
        want = polarity_of(expected)
        if want is None:
            continue
        best, best_score = None, 0.0
        for s in steps:
            if not is_assertion(s):
                continue
            score = token_overlap(expected, s)
            if score > best_score:
                best, best_score = s, score
        if best is None or best_score < 0.34:
            continue
        got = polarity_of(best)
        if got is not None and got != want:
            add("blocker", "polarity-drift",
                "шаг %d: ожидание «%s», а сценарий проверяет «%s»"
                % (n, "отсутствие" if want == "negative" else "наличие",
                   "отсутствие" if got == "negative" else "наличие"),
                "ожидание: %s\n  шаг:      %s" % (expected.strip(), best))

    # 3. Ожидание вообще не проверяется.
    if any((st.get("expected_result") or "").strip() for st in model_steps(case)):
        if not any(is_assertion(s) for s in steps):
            add("blocker", "no-assertion",
                "в сценарии нет ни одного шага-проверки",
                "в тест-модели есть expected_result, в сценарии — только подготовка и действие")

    # 4. Именованные объекты: топик, кэш, домен.
    model_names = set()
    for st in model_steps(case):
        model_names |= named_objects(st.get("description"))
        model_names |= named_objects(st.get("expected_result"))
    model_names |= named_objects(case.get("precondition"))
    actual_names = named_objects(actual_all) | named_objects(" ".join(scenario["background"]))
    lost = sorted(n for n in model_names
                  if not any(n.lower() == a.lower() for a in actual_names))
    for name in lost:
        add("major", "object-missing",
            "объект «%s» из тест-модели не встречается в сценарии" % name,
            "проверь, не подменён ли топик/кэш/домен")

    # 5. Шаг тест-модели не отражён в сценарии. Сверка идёт по телу сценария, а
    # не по одним шагам: половина значений живёт в таблицах под шагом
    # (`| domains | RETAIL |`), и без них покрытый шаг выглядел бы потерянным.
    for n, st in enumerate(model_steps(case), start=1):
        descr = (st.get("description") or "").strip()
        if not descr:
            continue
        if token_overlap(descr, actual_all) < 0.34:
            add("major", "step-uncovered",
                "шаг %d тест-модели не нашёл соответствия в сценарии" % n, descr)

    # 6. Проверка, которой нет в тест-модели. Считаются только шаги-проверки:
    # шаги подготовки и действия берутся у донора по форме, и расхождение их
    # формулировок с тест-моделью — норма, а не находка. Лишняя же проверка
    # означает, что сценарий проверяет что-то своё.
    model_text = " \n ".join(
        [(st.get("description") or "") + " " + (st.get("expected_result") or "")
         for st in model_steps(case)] + [case.get("name") or "", case.get("precondition") or ""])
    for s in steps:
        if is_utility(s) or not is_assertion(s):
            continue
        if token_overlap(s, model_text) < 0.34:
            add("minor", "assertion-extra",
                "сценарий проверяет то, чего нет в тест-модели", s)

    # 7. Предусловие.
    precondition = (case.get("precondition") or "").strip()
    if precondition:
        haystack = actual_all + " \n " + " \n ".join(scenario["background"])
        if token_overlap(precondition, haystack) < 0.34:
            add("major", "precondition-missing",
                "предусловие не отражено ни в Предыстории файла, ни в шагах",
                precondition)

    # 8. Стенд.
    stand = (case.get("stand") or "").strip()
    if stand and stand not in scenario["tags"]:
        add("minor", "stand-mismatch",
            "стенд в тест-модели %s, среди тегов сценария его нет" % stand,
            "теги: %s" % (" ".join(scenario["tags"]) or "—"))

    return findings


def verdict_of(findings):
    if any(f["severity"] == "blocker" for f in findings):
        return "BLOCK"
    if any(f["severity"] == "major" for f in findings):
        return "REQUEST CHANGES"
    return "APPROVE"


# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------
def report(model_path, project, cases, index, wanted, out):
    findings = []
    reviewed, missing, not_automated = [], [], []

    for case in cases:
        cid = case.get("id")
        if not cid:
            findings.append({"severity": "major", "kind": "no-id", "id": "(без id)",
                             "text": "у сценария тест-модели нет id — сверять не с чем",
                             "detail": ""})
            continue
        if wanted and cid not in wanted:
            continue
        scenario = index.get(cid)
        if scenario is None:
            if case.get("feature"):
                findings.append({"severity": "blocker", "kind": "scenario-missing", "id": cid,
                                 "text": "в тест-модели проставлен feature, но тега @%s в файлах нет" % cid,
                                 "detail": "feature: %s" % case.get("feature")})
                missing.append(cid)
            else:
                not_automated.append(cid)
            continue
        reviewed.append(cid)
        findings.extend(review_case(case, scenario))

    verdict = verdict_of(findings)

    out.append("## Autotest Review")
    out.append("")
    out.append("Тест-модель: %s" % os.path.relpath(model_path, project).replace("\\", "/"))
    out.append("Сверено сценариев: %d · не автоматизировано: %d · потеряно: %d"
               % (len(reviewed), len(not_automated), len(missing)))
    out.append("")
    out.append("VERDICT: %s" % verdict)
    out.append("")

    by_sev = {s: [f for f in findings if f["severity"] == s] for s in SEVERITIES}
    titles = {"blocker": "Blockers", "major": "Major", "minor": "Minor"}
    for sev in SEVERITIES:
        items = by_sev[sev]
        out.append("### %s: %d" % (titles[sev], len(items)))
        for f in items:
            out.append("- [%s] %s — %s" % (f["kind"], f["id"], f["text"]))
            if f["detail"]:
                for line in f["detail"].split("\n"):
                    out.append("  %s" % line.strip())
        out.append("")

    if not_automated:
        out.append("Не автоматизированы (нет feature: в тест-модели): %s"
                   % ", ".join(sorted(not_automated)))
        out.append("")
    out.append("Сверка механическая: канал проверки, полярность, именованные объекты, "
               "покрытие шагов. Смысл проверки за человеком.")
    return verdict, findings


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="ключ релиза ASFMSTD-NNNN либо путь к YAML")
    ap.add_argument("--project", default=".")
    ap.add_argument("--ids", default="", help="только эти id, через запятую")
    ap.add_argument("--json", action="store_true", help="машинный вывод")
    args = ap.parse_args()

    project = args.project
    if not os.path.isdir(project):
        die("каталог проекта не найден: %s" % project)

    model_path, model = load_model(args.target, project)
    cases = [c for c in model["test_cases"] if isinstance(c, dict)]
    index = find_scenarios(project)
    wanted = {i.strip() for i in args.ids.split(",") if i.strip()}
    unknown = sorted(wanted - {c.get("id") for c in cases})
    if unknown:
        die("в тест-модели нет id: %s" % ", ".join(unknown))

    out = []
    verdict, findings = report(model_path, project, cases, index, wanted, out)

    if args.json:
        print(json.dumps({"verdict": verdict, "findings": findings},
                         ensure_ascii=False, indent=2))
    else:
        print("\n".join(out))

    return 0 if verdict == "APPROVE" else 1


if __name__ == "__main__":
    sys.exit(main())
