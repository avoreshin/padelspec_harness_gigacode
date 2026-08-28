#!/usr/bin/env python3
"""export-testcases-xml.py — третий шаг конвейера: тест-модель → XML для Zephyr Scale.

MCP к TMS в инсталляции нет, API закрыт. Zephyr Scale принимает массовую
загрузку файлом через интерфейс, поэтому выгрузка делается XML-файлом, который
человек загружает руками.

    /generate-test-cases   →  docs/testcases/<release>.yaml
    /generate-autotests    →  *.feature  (+ YAML: feature:, Автоматизирован: Да)
    /export-testcases-xml  →  docs/testcases/<release>.xml   ← этот скрипт

Порядок именно такой: XML собирается после генерации автотестов, чтобы в Zephyr
уезжали кейсы с уже проставленным признаком автоматизации.

Использование:
  export-testcases-xml.py <release-key|path.yaml> [--project DIR] [--out FILE] [--force]

Коды возврата:
  0 — XML записан
  1 — тест-модель не прошла проверку либо XML уже существует (нужен --force)
  2 — ошибка вызова или YAML не разобран
"""

import argparse
import io
import os
import re
import sys
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Маппинг YAML → XML. Всё, что зависит от диалекта Zephyr, живёт здесь и только
# здесь: меняется схема импорта — правится этот блок, остальной код не трогается.
# ---------------------------------------------------------------------------
TAG_ROOT = "testCases"
TAG_CASE = "testCase"
TAG_SIMPLE = (              # (поле YAML, тег XML)
    ("name", "name"),
    ("objective", "objective"),
    ("precondition", "precondition"),
    ("status", "status"),
    ("priority", "priority"),
    ("folder", "folder"),
)
TAG_LABELS, TAG_LABEL = "labels", "label"
TAG_CUSTOM, TAG_CUSTOM_ONE, ATTR_CUSTOM_NAME = "customFields", "customField", "name"
TAG_SCRIPT, ATTR_SCRIPT_TYPE, VAL_SCRIPT_TYPE = "testScript", "type", "STEPS"
TAG_STEPS, TAG_STEP, ATTR_STEP_INDEX = "steps", "step", "index"
TAG_STEP_DESC, TAG_STEP_EXPECTED = "description", "expectedResult"

DEFAULTS = {"status": "Актуальный", "priority": "Medium"}


def die(msg, code=2):
    sys.stderr.write("ERROR %s\n" % msg)
    sys.exit(code)


# ---------------------------------------------------------------------------
# Чтение YAML
#
# PyYAML в целевом проекте (Java/Maven) может не стоять, а тест-модель читать
# надо. Поэтому есть свой разбор подмножества, которым описана схема тест-модели.
# Он намеренно строгий: конструкция, которой он не знает, — это ошибка с номером
# строки, а не молча пропущенная строка. Молчаливый пропуск здесь опаснее всего:
# из тест-модели уедет в TMS неполный кейс, и человек этого не увидит.
# PDLS_XML_YAML=stdlib принудительно включает свой разбор — так его гоняют тесты
# на машине, где PyYAML есть.
# ---------------------------------------------------------------------------
def load_yaml(path):
    text = io.open(path, encoding="utf-8").read()
    if os.environ.get("PDLS_XML_YAML") != "stdlib":
        try:
            import yaml
            return yaml.safe_load(text) or {}
        except ImportError:
            pass
    return MiniYaml(text, path).parse()


SCALAR_RE = re.compile(r'^(?P<key>[^:#]+?)\s*:\s*(?P<val>.*)$')


class MiniYaml(object):
    """Разбор подмножества YAML, которым описана тест-модель."""

    def __init__(self, text, path):
        self.path = path
        self.lines = []
        for no, raw in enumerate(text.split("\n"), 1):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            self.lines.append((no, raw))
        self.i = 0

    def fail(self, no, line, why):
        die("%s:%d: %s\n  %s\n  PyYAML разобрал бы это лучше: pip install pyyaml"
            % (self.path, no, why, line.strip()), 2)

    def indent(self, line):
        return len(line) - len(line.lstrip(" "))

    def parse(self):
        return self.block(0)

    def block(self, min_indent):
        """Читает узел: список (строки '- ') либо отображение."""
        if self.i >= len(self.lines):
            return {}
        no, line = self.lines[self.i]
        if line.lstrip().startswith("- "):
            return self.seq(self.indent(line))
        return self.mapping(min_indent)

    def mapping(self, indent):
        out = {}
        while self.i < len(self.lines):
            no, line = self.lines[self.i]
            cur = self.indent(line)
            if cur < indent:
                break
            if cur > indent:
                self.fail(no, line, "неожиданный сдвиг вправо")
            if line.lstrip().startswith("- "):
                break
            m = SCALAR_RE.match(line.strip())
            if not m:
                self.fail(no, line, "строка не похожа на 'ключ: значение'")
            key, val = m.group("key").strip(), m.group("val").strip()
            self.i += 1
            if val == "":
                child_indent = self.peek_indent()
                if child_indent is None or child_indent <= indent:
                    out[key] = None
                else:
                    out[key] = self.block(child_indent)
            else:
                out[key] = self.scalar(no, line, val)
        return out

    def seq(self, indent):
        out = []
        while self.i < len(self.lines):
            no, line = self.lines[self.i]
            cur = self.indent(line)
            if cur < indent or not line.lstrip().startswith("- "):
                break
            if cur > indent:
                self.fail(no, line, "элемент списка сдвинут вправо")
            rest = line.lstrip()[2:].strip()
            m = SCALAR_RE.match(rest)
            if not m:
                # элемент-скаляр: '- значение'
                self.i += 1
                out.append(self.scalar(no, line, rest))
                continue
            # элемент-отображение: первая пара на строке дефиса, остальные ниже
            item_indent = cur + 2
            key, val = m.group("key").strip(), m.group("val").strip()
            self.i += 1
            item = {}
            if val == "":
                nxt = self.peek_indent()
                item[key] = self.block(nxt) if nxt is not None and nxt > item_indent else None
            else:
                item[key] = self.scalar(no, line, val)
            rest_map = self.mapping(item_indent)
            item.update(rest_map)
            out.append(item)
        return out

    def peek_indent(self):
        if self.i >= len(self.lines):
            return None
        return self.indent(self.lines[self.i][1])

    def scalar(self, no, line, val):
        val = self.strip_comment(val)
        if val.startswith("[") and val.endswith("]"):
            inner = val[1:-1].strip()
            if not inner:
                return []
            return [self.unquote(p.strip()) for p in self.split_flow(inner)]
        if val.startswith("{") and val.endswith("}"):
            out = {}
            inner = val[1:-1].strip()
            for part in self.split_flow(inner) if inner else []:
                m = SCALAR_RE.match(part.strip())
                if not m:
                    self.fail(no, line, "не разобрана пара в {…}")
                out[m.group("key").strip()] = self.unquote(m.group("val").strip())
            return out
        if val in ("|", ">", "|-", ">-"):
            self.fail(no, line, "блочные скаляры (| и >) не поддерживаются")
        return self.unquote(val)

    @staticmethod
    def split_flow(s):
        """Разрез по запятым верхнего уровня, запятая внутри кавычек не считается."""
        parts, buf, quote = [], "", None
        for ch in s:
            if quote:
                if ch == quote:
                    quote = None
                buf += ch
            elif ch in "\"'":
                quote = ch
                buf += ch
            elif ch == ",":
                parts.append(buf)
                buf = ""
            else:
                buf += ch
        if buf.strip():
            parts.append(buf)
        return parts

    @staticmethod
    def strip_comment(val):
        """Хвостовой '#' — комментарий, но только вне кавычек."""
        quote = None
        for idx, ch in enumerate(val):
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "\"'":
                quote = ch
            elif ch == "#" and idx > 0 and val[idx - 1] == " ":
                return val[:idx].strip()
        return val.strip()

    @staticmethod
    def unquote(val):
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            return val[1:-1]
        return val


# ---------------------------------------------------------------------------
# Проверка тест-модели
# ---------------------------------------------------------------------------
def validate(model, path):
    problems = []
    cases = model.get("test_cases")
    if not isinstance(cases, list) or not cases:
        die("%s: блок test_cases пуст или отсутствует — выгружать нечего" % path, 1)

    seen = {}
    for pos, case in enumerate(cases, 1):
        if not isinstance(case, dict):
            problems.append("сценарий №%d — не отображение" % pos)
            continue
        cid = case.get("id") or "№%d" % pos
        if not case.get("id"):
            problems.append("%s — нет поля id, после импорта не сопоставить с тегом @gen-*" % cid)
        elif cid in seen:
            problems.append("%s — id повторяется (сценарии %d и %d)" % (cid, seen[cid], pos))
        else:
            seen[cid] = pos
        if not case.get("name"):
            problems.append("%s — нет поля name" % cid)
        steps = ((case.get("script") or {}).get("steps")) if isinstance(case.get("script"), dict) else None
        if not isinstance(steps, list) or not steps:
            problems.append("%s — нет шагов (script.steps)" % cid)
            continue
        for n, step in enumerate(steps, 1):
            if not isinstance(step, dict) or not step.get("description"):
                problems.append("%s — шаг %d без description" % (cid, n))
            elif not step.get("expected_result"):
                problems.append("%s — шаг %d без expected_result" % (cid, n))
    return problems


# ---------------------------------------------------------------------------
# Сборка XML
# ---------------------------------------------------------------------------
def build_xml(model, release):
    root = ET.Element(TAG_ROOT)
    defaulted = {"folder": 0, "status": 0, "priority": 0}
    automated = 0

    for case in model["test_cases"]:
        node = ET.SubElement(root, TAG_CASE)
        values = dict(case)
        if not values.get("folder"):
            values["folder"] = "/%s/" % release
            defaulted["folder"] += 1
        for field in ("status", "priority"):
            if not values.get(field):
                values[field] = DEFAULTS[field]
                defaulted[field] += 1

        for field, tag in TAG_SIMPLE:
            val = values.get(field)
            if val:
                ET.SubElement(node, tag).text = str(val)

        # id уходит отдельным label: после импорта Zephyr выдаёт свои ключи
        # ASFMSTD-T####, и без метки их не сопоставить с тегами @gen-* в
        # feature-файлах. Связи story↔сценарий в репозитории нет — это
        # единственная нить обратно.
        labels = list(values.get("labels") or [])
        if values.get("id"):
            labels.insert(0, str(values["id"]))
        if labels:
            holder = ET.SubElement(node, TAG_LABELS)
            for label in labels:
                ET.SubElement(holder, TAG_LABEL).text = str(label)

        custom = values.get("custom_fields") or {}
        if custom:
            holder = ET.SubElement(node, TAG_CUSTOM)
            for key, val in custom.items():
                el = ET.SubElement(holder, TAG_CUSTOM_ONE)
                el.set(ATTR_CUSTOM_NAME, str(key))
                el.text = "" if val is None else str(val)
        if str(custom.get("Автоматизирован", "")).strip().lower() in ("да", "yes"):
            automated += 1

        script = ET.SubElement(node, TAG_SCRIPT)
        script.set(ATTR_SCRIPT_TYPE, VAL_SCRIPT_TYPE)
        steps = ET.SubElement(script, TAG_STEPS)
        for n, step in enumerate(case["script"]["steps"], 1):
            el = ET.SubElement(steps, TAG_STEP)
            el.set(ATTR_STEP_INDEX, str(n))
            ET.SubElement(el, TAG_STEP_DESC).text = str(step["description"])
            ET.SubElement(el, TAG_STEP_EXPECTED).text = str(step["expected_result"])

    return root, defaulted, automated


def write_xml(root, out_path):
    if hasattr(ET, "indent"):
        ET.indent(root, space="  ")
    tree = ET.ElementTree(root)
    tree.write(out_path, encoding="UTF-8", xml_declaration=True)
    with io.open(out_path, "a", encoding="utf-8") as fh:
        fh.write("\n")


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("target", help="ключ релиза ASFMSTD-NNNN либо путь к YAML")
    ap.add_argument("--project", default=".")
    ap.add_argument("--out")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    if args.target.endswith((".yaml", ".yml")) or os.sep in args.target:
        src = args.target if os.path.isabs(args.target) else os.path.join(args.project, args.target)
        release = os.path.splitext(os.path.basename(src))[0]
    else:
        release = args.target
        src = os.path.join(args.project, "docs", "testcases", "%s.yaml" % release)

    if not os.path.isfile(src):
        die("тест-модель не найдена: %s\n"
            "  Сначала постройте её командой generate-test-cases %s" % (src, release), 1)

    out = args.out or os.path.join(os.path.dirname(src), "%s.xml" % release)
    if os.path.exists(out) and not args.force:
        die("XML уже существует: %s\n"
            "  Повторная загрузка того же файла заведёт в Zephyr дубли кейсов.\n"
            "  Перезаписать:  --force" % out, 1)

    model = load_yaml(src)
    if not isinstance(model, dict):
        die("%s: корень тест-модели — не отображение" % src, 2)

    problems = validate(model, src)
    if problems:
        sys.stderr.write("❌ Выгрузка остановлена: тест-модель неполна\n\n")
        for p in problems:
            sys.stderr.write("  • %s\n" % p)
        sys.stderr.write("\nZephyr примет такой кейс и он станет мусором в TMS.\n"
                         "Ничего не записано: %s\n" % out)
        sys.exit(1)

    root, defaulted, automated = build_xml(model, str(model.get("release") or release))
    write_xml(root, out)

    total = len(model["test_cases"])
    print("## Export Test Cases XML — готово")
    print("Источник: %s (%d сценариев)" % (src, total))
    print("Записано: %s (%d <%s>)" % (out, total, TAG_CASE))
    print("")
    print("id каждого сценария ушёл отдельным label — по нему после импорта")
    print("сопоставляются выданные ключи ASFMSTD-T#### с тегами @gen-* в feature-файлах.")
    if any(defaulted.values()):
        print("")
        print("⚠️ Проставлено по умолчанию: folder %d · status %d · priority %d"
              % (defaulted["folder"], defaulted["status"], defaulted["priority"]))
    print("")
    print("📎 Автоматизировано: %d из %d — поле feature в XML не уходит, в маппинге его нет"
          % (automated, total))
    print("")
    print("Дальше: загрузить XML в Zephyr Scale через интерфейс (массовый импорт).")
    print("Проверить перед загрузкой:  head -40 %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
