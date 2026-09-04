#!/usr/bin/env python3
"""release-readiness.py — готовность релиза к прогону, когда разработка в другом репозитории.

Типовой расклад: автотесты живут отдельным репозиторием (`orchestrator-autotest`),
разработка — своим. Циклы при этом идут в разных репозиториях, разными людьми и
в разных сессиях, поэтому «запустить их одной командой» невозможно физически:
обвязка не может вести чужой цикл. Что возможно — **сверить состояние** по
общему артефакту, и он у циклов один: SDD.

Статус SDD и есть протокол между ними:

    draft        критерии ещё меняются — тест-модель по ним устареет молча
    approved     критерии зафиксированы → можно строить модель и сценарии
    implemented  dev-цикл по story закрыт → код существует, можно прогонять

Читать evidence bundle разработки не нужно и нельзя: он лежит по одному пути на
репозиторий, перезаписывается каждой задачей и обычно не под git. `implemented`
же ставится человеком ровно после фазы evidence (см. `commands/evidence.md`) и
живёт в файле, который тестировщик и так читает.

Одного обвязка не наблюдает никогда — какая сборка стоит на стенде. Это
подтверждает человек, и подтверждение уходит в свод по релизу, а не в допущение.

Использование:
  release-readiness.py <release-key|path.yaml> [--project DIR] [--sdd-dir DIR]
                       [--json]

Коды возврата:
  0 — READY: у каждой story SDD в статусе implemented
  1 — NOT READY: есть story, по которым разработка не закрыта
  2 — ошибка вызова либо тест-модель не разобрана
"""

import argparse
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с release-readiness.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


coverage = _load("_pdls_sddcov", "sdd-testcoverage.py")

# Что каждый статус разрешает. Порядок — от «ничего» к «всё».
STATUS_MEANING = {
    "":            (None, "SDD не найден — критерии не зафиксированы"),
    "draft":       (None, "черновик — критерии ещё меняются"),
    "deprecated":  (None, "отменён — по нему не тестируют"),
    "approved":    (None, "модель и сценарии — да, прогон — нет"),
    "implemented": (None, "готово к прогону"),
}
READY_STATUS = ("implemented",)
# approved достаточно, чтобы вести model → autotests → review: эти фазы
# выводятся из критериев, а не из кода. Проверяет их sdd-coverage-gate.
CRITERIA_STATUS = ("approved", "implemented")


def stories_of(cases):
    out = []
    for c in cases:
        st = (c.get("story") or "").strip()
        if st and st not in out:
            out.append(st)
    return out


def assess(cases, by_story):
    """→ список строк отчёта по каждой story."""
    rows = []
    for story in stories_of(cases):
        found = by_story.get(story) or []
        sdd = None
        # Берём самый «продвинутый» статус: story могла быть закрыта одним SDD
        # из нескольких, и черновик рядом с ним не отменяет факта.
        for candidate in found:
            if sdd is None or _rank(candidate.get("status")) > _rank(sdd.get("status")):
                sdd = candidate
        status = (sdd.get("status") if sdd else "") or ""
        rows.append({
            "story": story,
            "sdd": (sdd.get("id") if sdd else "") or (sdd["_path"] if sdd else ""),
            "path": sdd["_path"] if sdd else "",
            "status": status,
            "ready_to_run": status in READY_STATUS,
            "criteria_frozen": status in CRITERIA_STATUS,
            "cases": len([c for c in cases if (c.get("story") or "").strip() == story]),
        })
    return rows


def _rank(status):
    order = ("", "deprecated", "draft", "approved", "implemented")
    status = status or ""
    return order.index(status) if status in order else 0


def report(rows, sdd_dir, sdd_src, out):
    ready = all(r["ready_to_run"] for r in rows) and bool(rows)
    verdict = "READY" if ready else "NOT READY"

    out.append("## Release Readiness")
    out.append("")
    out.append("SDD: %s (%s)%s" % (sdd_dir, sdd_src,
                                   "" if os.path.isdir(sdd_dir) else "  ❌ каталога нет"))
    out.append("")
    out.append("VERDICT: %s" % verdict)
    out.append("")
    if not rows:
        # Пустая таблица и голое NOT READY не говорят ничего. Причина всегда
        # одна: в тест-модели ни у одного кейса не проставлена story, и
        # связать релиз с SDD не по чему.
        out.append("Ни у одного кейса тест-модели не проставлена story —")
        out.append("связать релиз с SDD не по чему. Сверка идёт по этому полю:")
        out.append("проставь `story:` кейсам либо перегенерируй тест-модель.")
        out.append("")
        out.append("Подробнее: python3 .claude/scripts/sdd-testcoverage.py <release> --project .")
        return verdict, ready
    out.append("%-16s %-34s %-14s %s" % ("STORY", "SDD", "СТАТУС", "ЧТО РАЗРЕШАЕТ"))
    for r in rows:
        means = STATUS_MEANING.get(r["status"], ("", "статус не из словаря SDD"))[1]
        out.append("%-16s %-34s %-14s %s"
                   % (r["story"], r["sdd"] or "—", r["status"] or "—", means))
    out.append("")

    blocked = [r for r in rows if not r["ready_to_run"]]
    if blocked:
        out.append("Прогон закрыт по %d story:" % len(blocked))
        for r in blocked:
            if not r["criteria_frozen"]:
                out.append("  %s — %s. Это работа человека: критерии пишет и утверждает он."
                           % (r["story"], STATUS_MEANING.get(r["status"], ("", "SDD не найден"))[1]))
            else:
                out.append("  %s — критерии готовы, но dev-цикл не закрыт. "
                           "Статус перейдёт в implemented после его фазы evidence."
                           % r["story"])
        out.append("")

    out.append("Чего обвязка не видит: какая сборка стоит на стенде. Даже при READY")
    out.append("подтвердить, что развёрнут коммит с этими story, обязан человек —")
    out.append("подтверждение уходит в свод по релизу, а не в допущение.")
    return verdict, ready


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="ключ релиза ASFMSTD-NNNN либо путь к YAML")
    ap.add_argument("--project", default=".")
    ap.add_argument("--sdd-dir", default="", help="каталог SDD; пусто — берётся из профиля")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    project = args.project
    if not os.path.isdir(project):
        die("каталог проекта не найден: %s" % project)

    extractor = coverage.extractor_path()
    if extractor is None:
        die("не найден extract-sdd-frontmatter.sh: разбирать SDD своими правилами нельзя")

    _model_path, model = coverage.load_model(args.target, project)
    cases = [c for c in model["test_cases"] if isinstance(c, dict)]
    sdd_dir, sdd_src = coverage.resolve_sdd_dir(project, args.sdd_dir)
    _sdds, by_story, _broken = coverage.collect_sdds(project, sdd_dir, extractor)

    rows = assess(cases, by_story)
    out = []
    verdict, ready = report(rows, sdd_dir, sdd_src, out)

    if args.json:
        print(json.dumps({"verdict": verdict, "stories": rows},
                         ensure_ascii=False, indent=2))
    else:
        print("\n".join(out))
    return 0 if ready else 1


if __name__ == "__main__":
    sys.exit(main())
