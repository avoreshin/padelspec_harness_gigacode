#!/usr/bin/env python3
"""harness-report.py — диагностический отчёт о состоянии обвязки.

ЗАЧЕМ. Разбор поломки по пересказу теряет ровно то, что нужно: код возврата
хука, порядок фаз, точный вид находки, версию бинарника. Скрипт снимает эти
факты сам и складывает в один файл.

ЧТО ОТЧЁТ НЕСЁТ И ЧЕГО В НЁМ НЕТ. Отчёт — про поведение обвязки, а не про
проект, поэтому собирается по принципу «структура и вердикты, но не
содержимое»:

  · ни одной строки из feature-файлов, тест-модели, SDD или описаний задач;
  · находки — видом и количеством, без текста сценария и ожидания;
  · пути — относительно корня репозитория;
  · ключи задач и релизов — псевдонимами (KEY-1, SDD-1): для разбора важна
    связность, а не сами идентификаторы. Соответствие пишется отдельным
    служебным файлом, который к отчёту не прикладывается;
  · всё, что похоже на секрет, номер карты, e-mail, IP или домен, вырезается
    ещё раз поверх этого — на случай, если оно затесалось в текст причины,
    написанный человеком.

Итоговая справка перечисляет, что внутри, чтобы просмотр занимал минуту, а не
чтение всего файла.

Использование:
  harness-report.py [--out FILE] [--project DIR] [--no-selftest]
                    [--release KEY] [--keep-keys]

  --no-selftest  не запускать tests/smoke/run-all.sh (он идёт минуты)
  --release KEY  дополнительно снять состояние конвейера тестировщика по релизу
  --keep-keys    НЕ псевдонимизировать ключи задач (осознанное решение)

Коды возврата:
  0 — отчёт собран · 1 — собран, но с ошибками сбора · 2 — ошибка вызова
"""

import argparse
import datetime
import io
import json
import os
import platform
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_VERSION = "1.0"

REQ_BINS = ("bash", "git", "jq", "node", "python3")
OPT_BINS = ("npm", "perl", "rsync", "mvn")


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat().replace("+00:00", "Z")


def run(cmd, cwd=None, timeout=900):
    """→ (rc, stdout, stderr). Никогда не бросает: сбой — это тоже факт."""
    try:
        p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        out, err = p.communicate(timeout=timeout)
        return (p.returncode,
                out.decode("utf-8", "replace"),
                err.decode("utf-8", "replace"))
    except subprocess.TimeoutExpired:
        p.kill()
        return 124, "", "timeout: %s" % " ".join(cmd)
    except OSError as e:
        return 127, "", str(e)


# ---------------------------------------------------------------------------
# Редактура. Всё, что попадает в отчёт из свободного текста, идёт через неё.
# ---------------------------------------------------------------------------
ISSUE_RE = re.compile(r'\b([A-Z][A-Z0-9]{1,15})-(\d{1,6})\b')

# Префиксы, которые выглядят как ключ задачи, но им не являются: кодировки,
# алгоритмы, стандарты и — важнее прочего — `AC-3`, идентификатор критерия.
# Подменять критерий псевдонимом ключа значит ломать ровно тот диагноз, ради
# которого отчёт и собирают, а заодно завышать счётчик псевдонимов.
NOT_ISSUE_PREFIXES = frozenset((
    "AC", "API", "AES", "CVE", "HTTP", "HTTPS", "ISO", "JSON", "MD", "RFC",
    "RSA", "SHA", "SQL", "SSL", "TLS", "UTC", "UTF", "XML", "YAML",
))
SDD_RE = re.compile(r'\bSDD-\d{8}-[a-z0-9-]+\b')

# Абсолютные пути. Свой домашний каталог скрипт вырезает подстановкой, но в
# тексте причины оказывается путь ЧУЖОЙ машины — и в нём имя учётной записи.
# От пути оставляем два последних сегмента: `docs/sdd` для диагноза нужен,
# `/home/<фамилия>/...` — нет.
ABS_POSIX_RE = re.compile(r'(?:/[\w.@%+-]+){3,}')
ABS_WIN_RE = re.compile(r'\b[A-Za-z]:\\(?:[\w.@%+-]+\\?){2,}')

# Порядок важен: сначала то, что длиннее и специфичнее.
SECRET_PATTERNS = (
    ("email",    re.compile(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b')),
    ("ipv4",     re.compile(r'\b(?:\d{1,3}\.){3}\d{1,3}\b')),
    ("pan",      re.compile(r'\b\d{13,19}\b')),
    ("token",    re.compile(r'\b[A-Za-z0-9_\-]{32,}\b')),
    ("host",     re.compile(r'\b(?:[a-z0-9-]+\.){2,}[a-z]{2,}\b', re.I)),
)


class Redactor(object):
    """Псевдонимы стабильны в пределах отчёта: связность видна, значения — нет."""

    def __init__(self, root, keep_keys=False):
        self.root = os.path.abspath(root)
        self.home = os.path.expanduser("~")
        self.keep_keys = keep_keys
        self.map = {}          # реальное → псевдоним (в отчёт не попадает)
        self._counters = {}
        self.hits = {}

    def _alias(self, kind, real):
        if real in self.map:
            return self.map[real]
        self._counters[kind] = self._counters.get(kind, 0) + 1
        alias = "%s-%d" % (kind, self._counters[kind])
        self.map[real] = alias
        return alias

    def _hit(self, kind):
        self.hits[kind] = self.hits.get(kind, 0) + 1

    def text(self, s, limit=300):
        """Свободный текст: сначала псевдонимы, затем вырезание секретов."""
        if not s:
            return s
        s = str(s)
        # Абсолютные пути внутри текста.
        s = s.replace(self.root + os.sep, "").replace(self.root, ".")
        if self.home:
            s = s.replace(self.home, "<home>")

        if not self.keep_keys:
            def sub_sdd(m):
                self._hit("sdd-key")
                return self._alias("SDD", m.group(0))
            s = SDD_RE.sub(sub_sdd, s)

            def sub_issue(m):
                if m.group(1) in NOT_ISSUE_PREFIXES:
                    return m.group(0)
                self._hit("issue-key")
                return self._alias("KEY", m.group(0))
            s = ISSUE_RE.sub(sub_issue, s)

        def tail(m):
            self._hit("abs-path")
            parts = [x for x in re.split(r'[/\\]', m.group(0)) if x]
            return "<abs>/" + "/".join(parts[-2:])
        s = ABS_WIN_RE.sub(tail, s)
        s = ABS_POSIX_RE.sub(tail, s)

        for kind, rx in SECRET_PATTERNS:
            def sub(m, kind=kind):
                self._hit(kind)
                return "<%s>" % kind
            s = rx.sub(sub, s)

        s = " ".join(s.split())
        return s[:limit]

    def key(self, k):
        """Ключ задачи или релиза как отдельное значение."""
        if not k:
            return k
        if self.keep_keys:
            return k
        if SDD_RE.match(k):
            self._hit("sdd-key")
            return self._alias("SDD", k)
        m = ISSUE_RE.match(k)
        if m and m.group(1) not in NOT_ISSUE_PREFIXES:
            self._hit("issue-key")
            return self._alias("KEY", k)
        return self.text(k, 64)


# ---------------------------------------------------------------------------
# Сборщики
# ---------------------------------------------------------------------------
def collect_harness(project, red):
    ver = ""
    vp = os.path.join(project, "VERSION")
    if os.path.isfile(vp):
        ver = io.open(vp, encoding="utf-8").read().strip()
    rc, out, _ = run(["git", "rev-parse", "--short", "HEAD"], cwd=project)
    head = out.strip() if rc == 0 else ""
    rc, out, _ = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=project)
    branch = out.strip() if rc == 0 else ""
    rc, out, _ = run(["git", "status", "--porcelain"], cwd=project)
    dirty = bool(out.strip()) if rc == 0 else None
    layout = "gigacode" if os.path.isdir(os.path.join(project, ".gigacode")) else "claude"
    return {"version": ver, "head": head, "branch": red.text(branch, 64),
            "dirty": dirty, "layout": layout}


def collect_environment():
    bins = []
    for name in REQ_BINS + OPT_BINS:
        path = shutil.which(name)
        entry = {"name": name, "present": bool(path), "required": name in REQ_BINS}
        if path:
            for args in (["--version"], ["-version"], ["version"]):
                rc, out, err = run([name] + args, timeout=15)
                text = (out or err).strip().split("\n")[0] if (out or err) else ""
                if rc == 0 and text:
                    entry["version"] = text[:80]
                    break
        bins.append(entry)
    return {
        "os": platform.system().lower(),
        "release": platform.release()[:60],
        "python": platform.python_version(),
        "binaries": bins,
    }


def collect_hooks(project, red):
    """Что зарегистрировано в settings.json и что из этого физически исполнимо."""
    out = {"registered": [], "missing": [], "not_executable": [], "syntax_errors": []}
    sp = os.path.join(project, ".claude", "settings.json")
    if not os.path.isfile(sp):
        return out
    try:
        data = json.load(io.open(sp, encoding="utf-8"))
    except ValueError as e:
        out["error"] = red.text(str(e))
        return out
    # Один хук штатно подписан на несколько событий (jsonl-audit-sink — на
    # четыре). Регистрация — своя у каждого события, а вот файл общий: проверять
    # его столько же раз значит и `bash -n` гонять вчетверо, и выдать в
    # attention один и тот же хук четырьмя строками.
    checked = {}
    for event, entries in (data.get("hooks") or {}).items():
        for entry in entries or []:
            for h in entry.get("hooks") or []:
                cmd = h.get("command") or ""
                name = os.path.basename(cmd)
                rec = {"event": event, "matcher": entry.get("matcher", ""), "hook": name}
                full = os.path.join(project, cmd)
                if cmd not in checked:
                    checked[cmd] = present = os.path.isfile(full)
                    if not present:
                        out["missing"].append(name)
                    else:
                        if not os.access(full, os.X_OK):
                            out["not_executable"].append(name)
                        rc, _o, err = run(["bash", "-n", full], timeout=30)
                        if rc != 0:
                            out["syntax_errors"].append(
                                {"hook": name, "error": red.text(err, 200)})
                rec["present"] = checked[cmd]
                out["registered"].append(rec)
    present = {os.path.join(project, ".claude", "hooks", f)
               for f in os.listdir(os.path.join(project, ".claude", "hooks"))
               if f.endswith(".sh")} if os.path.isdir(
                   os.path.join(project, ".claude", "hooks")) else set()
    wired = {os.path.join(project, (h.get("command") or ""))
             for entries in (data.get("hooks") or {}).values()
             for entry in entries or [] for h in entry.get("hooks") or []}
    out["unwired"] = sorted(os.path.basename(p) for p in (present - wired))
    return out


def collect_schemas(project, red):
    script = os.path.join(project, ".claude", "scripts", "validate-schemas.sh")
    if not os.path.isfile(script):
        return {"ran": False}
    rc, out, err = run(["bash", script, "all"], cwd=project)
    passed = failed = 0
    m = re.search(r'Summary:\s*(\d+)\s*passed,\s*(\d+)\s*failed', out)
    if m:
        passed, failed = int(m.group(1)), int(m.group(2))
    fails = [red.text(l, 200) for l in out.split("\n") if l.strip().startswith("✗")]
    return {"ran": True, "exit_code": rc, "passed": passed, "failed": failed,
            "failures": fails[:20],
            "stderr_head": red.text(err, 300) if rc not in (0, 1) else ""}


def collect_selftest(project, red):
    script = os.path.join(project, "tests", "smoke", "run-all.sh")
    if not os.path.isfile(script):
        return {"ran": False, "reason": "tests/smoke/run-all.sh отсутствует"}
    with io.open(os.devnull) as devnull:
        try:
            p = subprocess.Popen(["bash", script], cwd=project, stdin=devnull,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            raw, _ = p.communicate(timeout=1800)
            rc, out = p.returncode, raw.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            p.kill()
            return {"ran": True, "exit_code": 124, "timeout": True}
        except OSError as e:
            return {"ran": False, "reason": red.text(str(e))}
    tiers = [{"tier": t, "status": s}
             for t, s in re.findall(r'^\s+(T\d+)\s+—\s+(PASS|FAIL.*)$', out, re.M)]
    # Тиры печатают итог в одном из двух форматов. В первом прошедшие и упавшие
    # стоят раздельно, и брать оттуда только PASS значило бы занижать счёт ровно
    # на красном прогоне — том единственном, ради которого отчёт и собирают.
    total = sum(int(p) + int(f)
                for p, f in re.findall(r'PASS (\d+) · FAIL (\d+)', out))
    total += sum(int(n) for n in re.findall(r'Total:\s*(\d+)', out))
    failed = [red.text(l, 200) for l in out.split("\n") if l.strip().startswith("❌")]
    return {"ran": True, "exit_code": rc, "tiers": tiers, "cases": total,
            "failed_cases": failed[:40]}


def collect_audit(project, red):
    """Факты из append-only трейла. Тексты причин проходят редактуру."""
    adir = os.path.join(project, ".claude", "audit")
    out = {"files": 0, "lines": 0, "events": {}, "denies": [], "phases": [],
           "unparsable": 0}
    if not os.path.isdir(adir):
        return out
    denies = {}
    for name in sorted(os.listdir(adir)):
        if not name.endswith(".jsonl"):
            continue
        out["files"] += 1
        for line in io.open(os.path.join(adir, name), encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            out["lines"] += 1
            try:
                ev = json.loads(line)
            except ValueError:
                out["unparsable"] += 1
                continue
            kind = ev.get("event") or "unknown"
            out["events"][kind] = out["events"].get(kind, 0) + 1
            if ev.get("decision") == "deny":
                k = (ev.get("hook") or "?", ev.get("tool") or "?")
                rec = denies.setdefault(k, {"hook": k[0], "tool": k[1], "count": 0,
                                            "reason_head": ""})
                rec["count"] += 1
                if not rec["reason_head"]:
                    rec["reason_head"] = red.text(ev.get("reason"), 200)
            if kind == "phase_transition":
                out["phases"].append({
                    "task": red.key(ev.get("task_id") or ""),
                    "loop": ev.get("loop") or "dev",
                    "from": ev.get("from"), "to": ev.get("to"),
                    "status": ev.get("status"),
                    "iteration": ev.get("iteration"),
                    "risk_class": ev.get("risk_class"),
                })
    out["denies"] = sorted(denies.values(), key=lambda r: -r["count"])
    out["phases"] = out["phases"][-120:]
    return out


def collect_pipeline(project, red, release):
    """Состояние конвейера тестировщика: только вердикты и виды находок."""
    out = {}
    scripts = os.path.join(project, ".claude", "scripts")

    prof = os.path.join(scripts, "testproject-profile.py")
    if os.path.isfile(prof):
        rc, o, e = run(["python3", prof, "check", "--project", project], cwd=project)
        out["profile"] = {"exit_code": rc,
                          "stale": rc == 1,
                          "summary": red.text(o.replace("\n", " · "), 300)}

    if not release:
        return out

    def verdicts(script):
        path = os.path.join(scripts, script)
        if not os.path.isfile(path):
            return None
        rc, o, e = run(["python3", path, release, "--project", project], cwd=project)
        verdict = ""
        m = re.search(r'^VERDICT:\s*(.+)$', o, re.M)
        if m:
            verdict = m.group(1).strip()
        kinds = {}
        for k in re.findall(r'^- \[([a-z-]+)\]', o, re.M):
            kinds[k] = kinds.get(k, 0) + 1
        rec = {"exit_code": rc, "verdict": verdict, "findings": kinds}
        if rc == 2:
            rec["error_head"] = red.text(e or o, 300)
        return rec

    for script, key in (("sdd-testcoverage.py", "sdd_coverage"),
                        ("release-readiness.py", "readiness"),
                        ("autotest-review.py", "autotest_review")):
        v = verdicts(script)
        if v is not None:
            out[key] = v
    out["release"] = red.key(release)
    return out


# ---------------------------------------------------------------------------
def build(args):
    project = os.path.abspath(args.project)
    red = Redactor(project, keep_keys=args.keep_keys)
    errors = []

    def guarded(name, fn, *a):
        try:
            return fn(*a)
        except Exception as exc:                       # сбор не должен падать
            errors.append({"where": name, "error": red.text("%s: %s"
                                                            % (type(exc).__name__, exc))})
            return {"error": "не собрано"}

    report = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "redaction": {"mode": "keep-keys" if args.keep_keys else "safe"},
        "harness": guarded("harness", collect_harness, project, red),
        "environment": guarded("environment", collect_environment),
        "hooks": guarded("hooks", collect_hooks, project, red),
        "schemas": guarded("schemas", collect_schemas, project, red),
        "audit": guarded("audit", collect_audit, project, red),
        "pipeline": guarded("pipeline", collect_pipeline, project, red, args.release),
    }
    if args.no_selftest:
        report["selftest"] = {"ran": False, "reason": "пропущен по --no-selftest"}
    else:
        report["selftest"] = guarded("selftest", collect_selftest, project, red)

    report["redaction"]["replacements"] = red.hits
    report["redaction"]["aliases"] = len(red.map)
    report["errors"] = errors
    return report, red


def summarize(rep):
    """Что смотреть первым делом. Порядок — по цене ошибки."""
    items = []
    h = rep.get("hooks") or {}
    if h.get("missing"):
        items.append("хуки зарегистрированы, но файлов нет: %s" % ", ".join(h["missing"]))
    if h.get("not_executable"):
        items.append("хуки зарегистрированы, но не исполняемые: %s"
                     % ", ".join(h["not_executable"]))
    if h.get("syntax_errors"):
        items.append("хуки не парсятся: %s"
                     % ", ".join(x["hook"] for x in h["syntax_errors"]))
    if h.get("unwired"):
        items.append("файлы хуков есть, но не подключены: %s" % ", ".join(h["unwired"]))
    for b in (rep.get("environment") or {}).get("binaries") or []:
        if b.get("required") and not b.get("present"):
            items.append("нет обязательного бинарника: %s" % b["name"])
    s = rep.get("schemas") or {}
    if s.get("ran") and s.get("failed"):
        items.append("схемы не проходят валидацию: %d" % s["failed"])
    st = rep.get("selftest") or {}
    if st.get("ran") and st.get("exit_code") not in (0, None):
        bad = [t["tier"] for t in st.get("tiers") or [] if t["status"] != "PASS"]
        items.append("самотест красный%s" % (": " + ", ".join(bad) if bad else ""))
    # Отказы считаются по паре (хук, инструмент), а строка про них называет
    # только хук: гейт, отклонявший Bash и Write, читался как два разных. Хуже
    # того, каждая пара занимала свою строку — при живом трейле одиннадцать
    # строк про отказы вытесняли из видимой части вердикты конвейера, хотя
    # порядок здесь и заведён по цене ошибки.
    by_hook = {}
    for d in (rep.get("audit") or {}).get("denies") or []:
        by_hook[d["hook"]] = by_hook.get(d["hook"], 0) + d["count"]
    if by_hook:
        top = sorted(by_hook.items(), key=lambda kv: (-kv[1], kv[0]))[:5]
        tail = len(by_hook) - len(top)
        items.append("гейты отклоняли вызовы: %s%s"
                     % (", ".join("%s×%d" % kv for kv in top),
                        (" и ещё %d" % tail) if tail > 0 else ""))
    p = rep.get("pipeline") or {}
    for key, label in (("sdd_coverage", "покрытие AC"), ("autotest_review", "сверка сценариев"),
                       ("readiness", "готовность релиза")):
        v = p.get(key) or {}
        if v.get("verdict") and v["verdict"] not in ("APPROVE", "READY"):
            items.append("%s: %s (%s)" % (label, v["verdict"],
                                          ", ".join("%s×%d" % kv for kv in
                                                    sorted((v.get("findings") or {}).items()))
                                          or "без разбивки"))
    if rep.get("errors"):
        items.append("сбор частично не удался: %s"
                     % ", ".join(e["where"] for e in rep["errors"]))
    return items


def render_md(rep, findings, out_json, keymap_path):
    L = []
    h = rep.get("harness") or {}
    L.append("# Отчёт обвязки — %s" % rep["generated_at"])
    L.append("")
    L.append("Версия %s · ветка `%s` · HEAD `%s`%s"
             % (h.get("version") or "—", h.get("branch") or "—",
                h.get("head") or "—", " · рабочее дерево грязное" if h.get("dirty") else ""))
    L.append("")
    L.append("## На что смотреть")
    L.append("")
    if findings:
        for f in findings:
            L.append("- %s" % f)
    else:
        L.append("- Ничего аномального: хуки на месте, схемы валидны, самотест зелёный.")
    L.append("")
    L.append("## Что внутри артефакта")
    L.append("")
    L.append("| Раздел | Что несёт |")
    L.append("|---|---|")
    L.append("| harness | версия, ветка, HEAD, чистота дерева |")
    L.append("| environment | ОС и версии бинарников |")
    L.append("| hooks | привязки из settings.json, наличие файлов, `bash -n` |")
    L.append("| schemas | итог `validate-schemas.sh all` |")
    L.append("| selftest | tier'ы smoke-набора и упавшие кейсы |")
    L.append("| audit | счётчики событий, отказы гейтов, переходы фаз |")
    L.append("| pipeline | вердикты и **виды** находок конвейера |")
    L.append("")
    L.append("## Чего внутри нет")
    L.append("")
    L.append("Ни строки из feature-файлов, тест-модели, SDD и описаний задач. "
             "Находки — видом и количеством. Пути — относительно корня репозитория. "
             "E-mail, IP, домены, длинные токены и последовательности цифр вырезаны.")
    r = rep.get("redaction") or {}
    if r.get("mode") == "safe":
        L.append("")
        L.append("Ключи задач заменены псевдонимами (`KEY-1`, `SDD-1`), всего %d. "
                 "Соответствие — в служебном файле `%s`, к отчёту он не относится."
                 % (r.get("aliases") or 0, keymap_path))
    else:
        L.append("")
        L.append("⚠️ Режим `--keep-keys`: ключи задач оставлены как есть — это было "
                 "осознанное решение при сборке.")
    if r.get("replacements"):
        L.append("")
        L.append("Срабатывания редактуры: %s"
                 % ", ".join("%s×%d" % kv for kv in sorted(r["replacements"].items())))
    L.append("")
    L.append("## Проверка")
    L.append("")
    L.append("`%s` — обычный текстовый JSON, его можно прочитать целиком. Если "
             "что-то в нём выглядит лишним, удали руками: файл не подписан и не "
             "проверяется на целостность, ломать его правкой нечего."
             % os.path.basename(out_json))
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--project", default=".")
    ap.add_argument("--out", default="")
    ap.add_argument("--release", default="", help="снять состояние конвейера по релизу")
    ap.add_argument("--no-selftest", action="store_true")
    ap.add_argument("--keep-keys", action="store_true",
                    help="не псевдонимизировать ключи задач")
    args = ap.parse_args()

    if not os.path.isdir(args.project):
        die("каталог проекта не найден: %s" % args.project)

    report, red = build(args)
    findings = summarize(report)
    report["attention"] = findings

    project = os.path.abspath(args.project)
    stamp = report["generated_at"].replace(":", "").replace("-", "")
    outdir = os.path.join(project, "docs", "harness-reports")
    path = args.out or os.path.join(outdir, "harness-report-%s.json" % stamp)
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)
    io.open(path, "w", encoding="utf-8").write(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    keymap_rel = ""
    if red.map and not args.keep_keys:
        kp = os.path.splitext(path)[0] + ".keymap.json"
        io.open(kp, "w", encoding="utf-8").write(
            json.dumps({"note": "Служебный файл: соответствие псевдонимов отчёта "
                                "реальным ключам. К отчёту не прикладывается.",
                        "aliases": {v: k for k, v in red.map.items()}},
                       ensure_ascii=False, indent=2) + "\n")
        keymap_rel = os.path.relpath(kp, project).replace("\\", "/")

    md_path = os.path.splitext(path)[0] + ".md"
    io.open(md_path, "w", encoding="utf-8").write(
        render_md(report, findings, path, keymap_rel or "(псевдонимов нет)"))

    rel = os.path.relpath(path, project).replace("\\", "/")
    print("## Harness Report")
    print("")
    print("Версия: %s · самотест: %s" % (
        (report.get("harness") or {}).get("version") or "—",
        "не запускался" if not (report.get("selftest") or {}).get("ran")
        else ("зелёный" if (report.get("selftest") or {}).get("exit_code") == 0 else "КРАСНЫЙ")))
    print("")
    if findings:
        print("На что смотреть: %d" % len(findings))
        for f in findings[:10]:
            print("  · %s" % f)
    else:
        print("Аномалий не найдено.")
    print("")
    print("Отчёт:     %s" % rel)
    print("Справка:   %s" % os.path.relpath(md_path, project).replace("\\", "/"))
    if keymap_rel:
        print("Служебный: %s (соответствие псевдонимов, к отчёту не относится)" % keymap_rel)
    return 1 if report.get("errors") else 0


if __name__ == "__main__":
    sys.exit(main())
