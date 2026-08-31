#!/usr/bin/env python3
"""collect-test-evidence.py — свод по релизу для цикла тестирования.

Аналог `collect-evidence.sh` из dev-цикла, но собирается из другого материала.
В dev-цикле доказательство — diff по коду плюс прогон тестов против SDD; здесь
кода нет вовсе, а acceptance criteria — тест-модель `docs/testcases/<release>.yaml`.
Поэтому фиксируются: сколько кейсов в модели, сколько сценариев реально лежит в
feature-файлах, вердикт сверки с моделью, результат прогона по тегам и что
осталось человеку.

Отдельным блоком идёт покрытие acceptance criteria из SDD: сверка сценариев
отвечает «сценарий делает то, что просила тест-модель», а этот блок — «сама
тест-модель покрывает то, что зафиксировано в SDD». Блока нет вовсе, если в
проекте нет `docs/sdd/`.

Три поля скрипт не выводит и не выдумывает — они приходят аргументами от того,
кто их наблюдал: статус прогона, ключ загрузки в TMS и файл XML. Прогон трогает
общий стенд, а загрузку в Zephyr делает человек; выдать «passed» по умолчанию
значило бы записать в доказательство то, чего не было.

Использование:
  collect-test-evidence.py <release> [--project DIR] [--out FILE]
                           [--run-status passed|failed|not_run] [--run-tags T]
                           [--run-verdict clean|fix|out-of-scope|infra|unknown]
                           [--export-file F] [--uploaded]

Коды возврата:
  0 — записано · 1 — тест-модель не найдена либо не разобрана · 2 — ошибка вызова
"""

import argparse
import datetime
import importlib.util
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def utc_now():
    """RFC3339 в UTC. Локальное время без зоны не проходит format: date-time —
    и это правильно: свод читают на другой машине, чем собирали."""
    return datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с collect-test-evidence.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


review = _load("_pdls_review", "autotest-review.py")
coverage = _load("_pdls_sddcov", "sdd-testcoverage.py")


def sdd_block(project, cases, sdd_dir="docs/sdd"):
    """Покрытие acceptance criteria из SDD — или None, если SDD в проекте нет.

    Свод обязан нести это отдельно от сверки сценариев: та отвечает «сценарий
    делает то, что просила тест-модель», а этот блок — «тест-модель покрывает
    то, что зафиксировано в SDD». Два разных утверждения, и второе до сих пор
    не проверял никто.
    """
    root = os.path.join(project, sdd_dir)
    if not os.path.isdir(root):
        return None, []
    extractor = coverage.extractor_path()
    if extractor is None:
        return None, []
    _sdds, by_story, broken = coverage.collect_sdds(project, sdd_dir, extractor)
    findings, covering, covered = coverage.review(cases, by_story, broken)
    acs = [(story, ac) for story, sdd in covering.items() for ac in sdd["_ac"]]
    block = {
        "verdict": coverage.verdict_of(findings),
        "stories": len(covering),
        "acceptance_criteria": len(acs),
        "covered": len([k for k in acs if covered.get(k)]),
        "documents": [
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
        "open_findings": [{"id": f["id"], "kind": f["kind"], "text": f["text"]}
                          for f in findings if f["severity"] != "minor"],
    }
    items = ["%s · %s: %s" % (f["id"], f["kind"], f["text"])
             for f in findings if f["severity"] in ("blocker", "major")]
    return block, items


def phases_from_audit(project, release):
    """Переходы тестового цикла по этому релизу — из append-only трейла.

    Читается тот же файл, что и всеми остальными потребителями состояния:
    отдельного хранилища у цикла нет намеренно, иначе состояние начало бы
    расходиться с аудитом.
    """
    out = []
    audit = os.path.join(project, ".claude", "audit")
    if not os.path.isdir(audit):
        return out
    for name in sorted(os.listdir(audit)):
        if not name.endswith(".jsonl"):
            continue
        for line in io.open(os.path.join(audit, name), encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line or '"event":"phase_transition"' not in line:
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            if ev.get("task_id") != release or ev.get("loop") != "testing":
                continue
            out.append({k: ev.get(k) for k in ("from", "to", "status", "timestamp", "reason")
                        if ev.get(k) is not None})
    return out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("release")
    ap.add_argument("--project", default=".")
    ap.add_argument("--sdd-dir", default="docs/sdd")
    ap.add_argument("--out", default="")
    ap.add_argument("--run-status", default="not_run", choices=("passed", "failed", "not_run"))
    ap.add_argument("--run-tags", default="")
    ap.add_argument("--run-verdict", default="",
                    choices=("", "clean", "fix", "out-of-scope", "infra", "unknown"))
    ap.add_argument("--run-log", default="")
    ap.add_argument("--export-file", default="")
    ap.add_argument("--uploaded", action="store_true",
                    help="человек подтвердил загрузку XML в Zephyr")
    args = ap.parse_args()

    project = args.project
    if not os.path.isdir(project):
        die("каталог проекта не найден: %s" % project)

    try:
        model_path, model = review.load_model(args.release, project)
    except SystemExit:
        die("тест-модель не найдена или не разобрана: %s" % args.release, 1)

    cases = [c for c in model["test_cases"] if isinstance(c, dict)]
    index = review.find_scenarios(project)

    out_lines = []
    verdict, findings = review.report(model_path, project, cases, index, set(), out_lines)
    # Сверенными считаются кейсы, у которых сценарий реально нашёлся в
    # feature-файлах: список строится по файлам, а не по намерению тест-модели.
    reviewed = [c["id"] for c in cases if c.get("id") and c["id"] in index]

    counts = {sev: len([f for f in findings if f["severity"] == sev]) for sev in review.SEVERITIES}
    not_automated = [c.get("id") for c in cases if c.get("id") and not c.get("feature")]
    files = sorted({index[cid]["path"] for cid in reviewed if cid in index})

    sdd, sdd_items = sdd_block(project, cases, args.sdd_dir)

    open_items = ["%s · %s: %s" % (f["id"], f["kind"], f["text"])
                  for f in findings if f["severity"] in ("blocker", "major")]
    open_items.extend(sdd_items)
    if args.run_status == "not_run":
        open_items.append("прогон по тегам не выполнялся — покрытие не подтверждено")
    if args.export_file and not args.uploaded:
        open_items.append("XML собран, но загрузка в Zephyr человеком не подтверждена")

    evidence = {
        "schema_version": "1.0",
        "release": args.release,
        "generated_at": utc_now(),
        "model": {
            "path": os.path.relpath(model_path, project).replace("\\", "/"),
            "test_cases": len(cases),
            "skipped": len(model.get("skipped") or []),
        },
        "autotests": {
            "scenarios": len(reviewed),
            "files": files,
            "not_automated": not_automated,
        },
        "review": {
            "verdict": verdict,
            "blockers": counts["blocker"],
            "major": counts["major"],
            "minor": counts["minor"],
            "open_findings": [{"id": f["id"], "kind": f["kind"], "text": f["text"]}
                              for f in findings if f["severity"] != "minor"],
        },
        "run": {"status": args.run_status},
        "phases": phases_from_audit(project, args.release),
        "open_items": open_items,
    }
    if sdd is not None:
        evidence["sdd"] = sdd
    if args.run_tags:
        evidence["run"]["tags"] = args.run_tags
    if args.run_verdict:
        evidence["run"]["verdict"] = args.run_verdict
    if args.run_log:
        evidence["run"]["log"] = args.run_log
    if args.export_file:
        evidence["export"] = {
            "file": args.export_file,
            "test_cases": len(cases),
            "uploaded_by_human": bool(args.uploaded),
        }

    path = args.out or os.path.splitext(model_path)[0] + ".evidence.json"
    io.open(path, "w", encoding="utf-8").write(
        json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")

    rel = os.path.relpath(path, project).replace("\\", "/")
    print("## Test Evidence — %s" % args.release)
    print("")
    print("Тест-модель:  %s (кейсов %d, отброшено %d)"
          % (evidence["model"]["path"], len(cases), evidence["model"]["skipped"]))
    print("Сценарии:     %d в %d файлах · не автоматизировано %d"
          % (len(reviewed), len(files), len(not_automated)))
    print("Ревью:        %s — blockers %d · major %d · minor %d"
          % (verdict, counts["blocker"], counts["major"], counts["minor"]))
    print("Прогон:       %s%s" % (args.run_status,
                                  (" (%s)" % args.run_verdict) if args.run_verdict else ""))
    if sdd is not None:
        print("SDD:          %s — story %d · AC покрыто %d из %d"
              % (sdd["verdict"], sdd["stories"], sdd["covered"],
                 sdd["acceptance_criteria"]))
    print("Фаз в трейле: %d" % len(evidence["phases"]))
    if open_items:
        print("")
        print("Осталось человеку: %d" % len(open_items))
        for item in open_items[:10]:
            print("  · %s" % item)
    print("")
    print("записан: %s" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
