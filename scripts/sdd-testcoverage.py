#!/usr/bin/env python3
"""sdd-testcoverage.py — сверка тест-модели релиза с acceptance criteria SDD.

Цикл тестирования сверял сценарии с тест-моделью, а саму тест-модель — ни с чем:
её порождал агент из описаний в трекере, и «человек её потом поправит» было
единственной гарантией. Цикл честно реализовывал модель, которая могла быть
неверной, и ни один гейт этого не видел.

Здесь закрывается именно этот разрыв, и закрывается **тем же артефактом, что и
dev-цикл**: acceptance criteria лежат в SDD (`docs/sdd/*.md`, §2.5 PDLC), секция
`## 4. Acceptance criteria` с блоками `AC-N` в Given-When-Then. Читаются они
**тем же** `extract-sdd-frontmatter.sh`, которым SDD валидируются в
`validate-schemas.sh` и в `sdd-schema-gate`: второй парсер разошёлся бы с первым
молча, и «покрыто» начало бы значить разное в двух местах.

Связь SDD ↔ story — строка `**Story**` в Metadata-таблице SDD. Поле опционально
для схемы (SDD, написанные раньше, обязаны остаться валидными) и обязательно
здесь: без него нельзя сказать, к какой story относятся критерии.

Использование:
  sdd-testcoverage.py <release-key|path.yaml> [--project DIR] [--sdd-dir DIR]
                      [--json]

Коды возврата (те же, что у autotest-review.py — их читает гейт):
  0 — APPROVE: каждая story релиза имеет approved-SDD, каждый AC покрыт
  1 — REQUEST CHANGES / BLOCK: есть находки
  2 — ошибка вызова либо тест-модель не разобрана
"""

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

AC_ID_RE = re.compile(r'\bAC-\d+\b')
SEVERITIES = ("blocker", "major", "minor")

# Статусы SDD, при которых критерии считаются зафиксированными. `draft` — не
# критерии: документ ещё меняется, и тест-модель, построенная по нему, устареет
# молча. `deprecated` — тем более.
ACCEPTED_STATUS = ("approved", "implemented")


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    """Соседний скрипт как модуль: разбор YAML уже написан, второй экземпляр
    разошёлся бы с первым молча."""
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с sdd-testcoverage.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


exporter = _load("_pdls_export", "export-testcases-xml.py")


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


def extractor_path():
    """Тот же экстрактор, которым SDD валидируются. Отсутствует — работать
    нельзя: подменять его собственным разбором значит завести второе мнение о
    том, что такое AC."""
    p = os.path.join(HERE, "extract-sdd-frontmatter.sh")
    return p if os.path.isfile(p) else None


def read_sdd(path, extractor):
    """→ dict экстрактора либо None, если файл не разобрался."""
    try:
        out = subprocess.check_output(["bash", extractor, path],
                                      stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, OSError):
        return None
    try:
        return json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return None


def ac_ids(sdd):
    """`AC-1: happy path` → `AC-1`. Порядок сохраняется, дубли схлопываются."""
    out = []
    for title in sdd.get("acceptance_criteria") or []:
        m = AC_ID_RE.search(title or "")
        if m and m.group(0) not in out:
            out.append(m.group(0))
    return out


def collect_sdds(project, sdd_dir, extractor):
    """→ (список SDD, карта story → [SDD]). Файлы, которые не разобрались,
    возвращаются отдельно: молча пропущенный SDD выглядит как отсутствующий."""
    root = sdd_dir if os.path.isabs(sdd_dir) else os.path.join(project, sdd_dir)
    sdds, broken = [], []
    if not os.path.isdir(root):
        return sdds, {}, broken
    for name in sorted(os.listdir(root)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(root, name)
        data = read_sdd(path, extractor)
        if data is None or data.get("error"):
            broken.append(os.path.relpath(path, project).replace("\\", "/"))
            continue
        data["_path"] = os.path.relpath(path, project).replace("\\", "/")
        data["_ac"] = ac_ids(data)
        sdds.append(data)
    by_story = {}
    for s in sdds:
        for story in s.get("stories") or []:
            by_story.setdefault(story, []).append(s)
    return sdds, by_story, broken


def case_acs(case):
    """`ac:` кейса: строка `AC-1`, строка `AC-1, AC-2` либо список."""
    raw = case.get("ac")
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        text = " ".join(str(x) for x in raw)
    else:
        text = str(raw)
    out = []
    for m in AC_ID_RE.findall(text):
        if m not in out:
            out.append(m)
    return out


# ---------------------------------------------------------------------------
# Правила сверки
# ---------------------------------------------------------------------------
def review(cases, by_story, broken):
    findings = []

    def add(sev, kind, ident, text, detail=""):
        findings.append({"severity": sev, "kind": kind, "id": ident,
                         "text": text, "detail": detail})

    for path in broken:
        add("blocker", "sdd-unreadable", path,
            "SDD не разобрался экстрактором — считать его отсутствующим нельзя",
            "проверь Metadata-таблицу и структуру секций: "
            "bash .claude/scripts/extract-sdd-frontmatter.sh %s" % path)

    # Порядок story — как в тест-модели: отчёт читают рядом с ней.
    stories = []
    for c in cases:
        st = (c.get("story") or "").strip()
        if st and st not in stories:
            stories.append(st)

    covering = {}          # story → SDD, по которому считается покрытие
    for story in stories:
        found = by_story.get(story) or []
        if not found:
            add("blocker", "story-no-sdd", story,
                "у story нет SDD: acceptance criteria не зафиксированы",
                "заведи SDD и укажи ключ в строке `**Story**` его Metadata-таблицы; "
                "шаблон — .claude/templates/SDD-template.md")
            continue
        accepted = [s for s in found if s.get("status") in ACCEPTED_STATUS]
        if not accepted:
            worst = found[0]
            add("blocker", "sdd-not-approved", story,
                "SDD %s в статусе «%s» — это ещё не критерии"
                % (worst.get("id") or worst["_path"], worst.get("status") or "—"),
                "%s\n  документ ещё меняется, и тест-модель по нему устареет молча"
                % worst["_path"])
            continue
        # Нескольких approved-SDD на одну story быть не должно: тогда неизвестно,
        # какой набор критериев считать полным.
        if len(accepted) > 1:
            add("blocker", "sdd-ambiguous", story,
                "story покрыта несколькими approved-SDD — какой набор критериев полный, неясно",
                ", ".join(s.get("id") or s["_path"] for s in accepted))
            continue
        sdd = accepted[0]
        if not sdd["_ac"]:
            add("blocker", "sdd-no-ac", story,
                "в SDD %s нет ни одного AC-*" % (sdd.get("id") or sdd["_path"]),
                "%s: секция `## 4. Acceptance criteria` пуста — сверять не с чем" % sdd["_path"])
            continue
        covering[story] = sdd

    # Ссылки кейсов: на существующий ли AC и есть ли она вообще.
    covered = {}           # (story, AC) → [id кейса]
    for case in cases:
        cid = case.get("id") or "(без id)"
        story = (case.get("story") or "").strip()
        sdd = covering.get(story)
        if sdd is None:
            continue       # причина уже названа выше, второй раз не повторяем
        acs = case_acs(case)
        if not acs:
            add("major", "case-no-ac", cid,
                "кейс не сослан ни на один AC",
                "story %s, SDD %s: проставь `ac: AC-N` — иначе неизвестно, "
                "какой критерий он проверяет" % (story, sdd.get("id") or sdd["_path"]))
            continue
        for ac in acs:
            if ac not in sdd["_ac"]:
                add("blocker", "ac-unknown", cid,
                    "кейс ссылается на %s, которого в SDD нет" % ac,
                    "%s: есть только %s" % (sdd.get("id") or sdd["_path"],
                                            ", ".join(sdd["_ac"])))
                continue
            covered.setdefault((story, ac), []).append(cid)

    # Непокрытый AC — главная находка: критерий записан, а проверять его нечем.
    for story, sdd in covering.items():
        for ac in sdd["_ac"]:
            if not covered.get((story, ac)):
                add("blocker", "ac-uncovered", story,
                    "%s не покрыт ни одним кейсом тест-модели" % ac,
                    "%s: критерий записан, а проверять его нечем" % sdd["_path"])

    return findings, covering, covered


def verdict_of(findings):
    if any(f["severity"] == "blocker" for f in findings):
        return "BLOCK"
    if any(f["severity"] == "major" for f in findings):
        return "REQUEST CHANGES"
    return "APPROVE"


def report(model_path, project, cases, findings, covering, covered, out):
    verdict = verdict_of(findings)
    stories = sorted(covering)
    total_ac = sum(len(s["_ac"]) for s in covering.values())
    hit_ac = len({k for k in covered})

    out.append("## SDD Coverage")
    out.append("")
    out.append("Тест-модель: %s" % os.path.relpath(model_path, project).replace("\\", "/"))
    out.append("Story с SDD: %d · AC покрыто: %d из %d · кейсов: %d"
               % (len(stories), hit_ac, total_ac, len(cases)))
    out.append("")
    out.append("VERDICT: %s" % verdict)
    out.append("")

    titles = {"blocker": "Blockers", "major": "Major", "minor": "Minor"}
    for sev in SEVERITIES:
        items = [f for f in findings if f["severity"] == sev]
        out.append("### %s: %d" % (titles[sev], len(items)))
        for f in items:
            out.append("- [%s] %s — %s" % (f["kind"], f["id"], f["text"]))
            if f["detail"]:
                for line in f["detail"].split("\n"):
                    out.append("  %s" % line.strip())
        out.append("")

    if covering:
        out.append("Покрытие по story:")
        for story in stories:
            sdd = covering[story]
            marks = []
            for ac in sdd["_ac"]:
                ids = covered.get((story, ac)) or []
                marks.append("%s%s" % (ac, "" if ids else " ✗"))
            out.append("  %-16s %-28s %s" % (story, sdd.get("id") or sdd["_path"],
                                             ", ".join(marks)))
        out.append("")
    out.append("Сверяется состав: у каждой story релиза есть approved-SDD, "
               "каждый его AC-* покрыт кейсом. Содержание критерия — за человеком.")
    return verdict


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="ключ релиза ASFMSTD-NNNN либо путь к YAML")
    ap.add_argument("--project", default=".")
    ap.add_argument("--sdd-dir", default="docs/sdd")
    ap.add_argument("--json", action="store_true", help="машинный вывод")
    args = ap.parse_args()

    project = args.project
    if not os.path.isdir(project):
        die("каталог проекта не найден: %s" % project)

    extractor = extractor_path()
    if extractor is None:
        die("не найден extract-sdd-frontmatter.sh рядом с sdd-testcoverage.py: "
            "разбирать SDD собственными правилами нельзя")

    model_path, model = load_model(args.target, project)
    cases = [c for c in model["test_cases"] if isinstance(c, dict)]
    _sdds, by_story, broken = collect_sdds(project, args.sdd_dir, extractor)

    findings, covering, covered = review(cases, by_story, broken)

    out = []
    verdict = report(model_path, project, cases, findings, covering, covered, out)

    if args.json:
        print(json.dumps({
            "verdict": verdict,
            "findings": findings,
            "coverage": [
                {"story": story,
                 "sdd": covering[story].get("id") or covering[story]["_path"],
                 "path": covering[story]["_path"],
                 "status": covering[story].get("status"),
                 "acceptance_criteria": [
                     {"ac": ac, "cases": covered.get((story, ac)) or []}
                     for ac in covering[story]["_ac"]
                 ]}
                for story in sorted(covering)
            ],
        }, ensure_ascii=False, indent=2))
    else:
        print("\n".join(out))

    return 0 if verdict == "APPROVE" else 1


if __name__ == "__main__":
    sys.exit(main())
