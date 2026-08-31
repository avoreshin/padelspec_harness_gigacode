#!/usr/bin/env python3
"""autotest-corpus.py — инвентарь тестового проекта для /generate-autotests.

Две задачи, обе детерминированные и без LLM:

1. Описание проекта. Скилл опирается на docs/testproject.md, docs/steps/*.md,
   docs/stashKeys.md и docs/tags.md, чтобы понимать, что где лежит. В проекте,
   где их не писали, скилл слеп. `describe` говорит, чего не хватает, `docs`
   собирает недостающее из кода и корпуса feature-файлов.

2. Поиск аналога. Новый сценарий почти никогда не первый в своём роде: проверка
   логирования в Kafka для модуля N делается так же, как для модуля M. `similar`
   ищет по всему корпусу сценарии-доноры и ранжирует их, показывая, из какого
   модуля каждый.

Команды:
  describe [--project DIR]                     чего не хватает из описания
  docs     [--project DIR] [--force]           сгенерировать недостающее
  similar  "<запрос>" [--project DIR] [--top N] [--print] [--exclude MODULE]

Коды возврата:
  0 — успех (для describe: всё описание на месте; для similar: доноры найдены)
  1 — describe: чего-то не хватает · similar: доноров нет
  2 — ошибка вызова, проект не похож на проект автотестов
"""

import argparse
import io
import os
import re
import sys
from collections import Counter, defaultdict

FEATURE_ROOTS = ("src/test/resources/features",)
STEPDEF_GLOBS = ("src/main/java", "src/test/java")

# Каталоги, в которые обход не заходит. Корни выше узкие, поэтому список —
# страховка от нестандартной раскладки проекта: сгенерированный или собранный
# .feature/.java, попавший в инвентарь, выглядит как настоящий донор шагов, и
# сценарий строится по коду, которого в исходниках нет.
IGNORED_DIRS = frozenset(
    (".git", ".gradle", ".idea", "__pycache__", "bin", "build", "node_modules", "out", "target")
)
# Потолок обхода. Ограничивает цену ошибки в аргументе (например, корень
# монорепозитория вместо модуля); обычный проект автотестов до него не достаёт.
MAX_WALK_FILES = 20000

# Русские и английские ключевые слова Gherkin. Первое слово строки-шага.
STEP_KEYWORDS = (
    "Дано", "Когда", "Тогда", "И", "Но", "Допустим", "Пусть", "Если", "То",
    "Также", "*", "Given", "When", "Then", "And", "But",
)
BLOCK_KEYWORDS = {
    "feature": ("Функционал:", "Функция:", "Feature:"),
    "background": ("Предыстория:", "Background:"),
    "scenario": ("Сценарий:", "Структура сценария:", "Scenario:", "Scenario Outline:"),
    "examples": ("Примеры:", "Examples:"),
}

ANNOTATION_RE = re.compile(
    r'@(?:Дано|Когда|Тогда|И|Но|Пусть|Given|When|Then|And|But)\s*\(\s*"((?:[^"\\]|\\.)*)"',
)
METHOD_RE = re.compile(r'public\s+[\w<>\[\],\s]+\s+(\w+)\s*\(')
STASH_USE_RE = re.compile(r'#\{([^}]+)\}')

# Слова, которые есть почти в каждом сценарии и потому ничего не различают.
STOPWORDS = {
    "что", "как", "для", "при", "если", "тогда", "когда", "дано", "и", "но",
    "the", "a", "an", "of", "in", "to", "is", "с", "в", "на", "по", "из", "за",
    "не", "то", "все", "есть", "быть", "этот", "тот", "или", "же",
}


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def norm(text):
    """Слова запроса и корпуса приводятся одинаково: нижний регистр, ё→е."""
    return text.lower().replace("ё", "е")


def tokens(text):
    return [w for w in re.findall(r"[\w-]{3,}", norm(text)) if w not in STOPWORDS]


def plural(n, one, few, many):
    """Согласование числительного: 1 сценарий, 3 сценария, 5 сценариев."""
    n = abs(n) % 100
    if 11 <= n <= 14:
        return many
    n %= 10
    if n == 1:
        return one
    if 2 <= n <= 4:
        return few
    return many


def stem(word):
    """Грубое отсечение окончания. Полноценный стеммер сюда не тянем: задача —
    чтобы «логирования» из запроса нашло «Логирование» в названии сценария."""
    return word[:max(4, len(word) - 3)]


def word_matches(query_word, corpus_word):
    """Совпадение по основе в обе стороны: какое из слов длиннее, заранее
    неизвестно («проверка» ↔ «проверяет», «логирования» ↔ «логирование»)."""
    return corpus_word.startswith(stem(query_word)) or query_word.startswith(stem(corpus_word))


def any_match(query_word, corpus_words):
    return any(word_matches(query_word, w) for w in corpus_words)


# ---------------------------------------------------------------------------
# Разбор корпуса
# ---------------------------------------------------------------------------
def walk_files(base):
    """os.walk с отсечением служебных каталогов и потолком на число файлов."""
    seen = 0
    for dirpath, dirnames, files in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS]
        for f in sorted(files):
            seen += 1
            if seen > MAX_WALK_FILES:
                return
            yield dirpath, f


def find_feature_files(project):
    out = []
    for root in FEATURE_ROOTS:
        base = os.path.join(project, root)
        if not os.path.isdir(base):
            continue
        for dirpath, f in walk_files(base):
            if f.endswith(".feature"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def find_stepdef_files(project):
    out = []
    for root in STEPDEF_GLOBS:
        base = os.path.join(project, root)
        if not os.path.isdir(base):
            continue
        for dirpath, f in walk_files(base):
            if "stepdefs" not in dirpath.replace("\\", "/").split("/"):
                continue
            if f.endswith(".java") or f.endswith(".kt"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def module_of(project, feature_path):
    """Модуль = каталог сценария относительно корня features."""
    rel = os.path.relpath(feature_path, project).replace("\\", "/")
    for root in FEATURE_ROOTS:
        if rel.startswith(root + "/"):
            inner = rel[len(root) + 1:]
            parts = inner.split("/")
            return "/".join(parts[:-1]) if len(parts) > 1 else "(корень)"
    return os.path.dirname(rel) or "(корень)"


def starts_with_any(line, prefixes):
    return any(line.startswith(p) for p in prefixes)


def parse_feature(path):
    """→ {feature, tags, background:[...], scenarios:[{name,line,tags,steps}]}"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")

    result = {"feature": "", "tags": [], "background": [], "scenarios": []}
    pending_tags = []
    current = None
    in_background = False

    for i, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("@"):
            pending_tags = [t for t in line.split() if t.startswith("@")]
            continue

        if starts_with_any(line, BLOCK_KEYWORDS["feature"]):
            result["feature"] = line.split(":", 1)[1].strip()
            result["tags"] = pending_tags
            pending_tags = []
            current, in_background = None, False
            continue

        if starts_with_any(line, BLOCK_KEYWORDS["background"]):
            current, in_background = None, True
            pending_tags = []
            continue

        if starts_with_any(line, BLOCK_KEYWORDS["scenario"]):
            current = {
                "name": line.split(":", 1)[1].strip(),
                "line": i,
                "tags": pending_tags,
                "steps": [],
            }
            result["scenarios"].append(current)
            pending_tags = []
            in_background = False
            continue

        if starts_with_any(line, BLOCK_KEYWORDS["examples"]):
            current, in_background = None, False
            continue

        first = line.split(" ", 1)[0]
        if first in STEP_KEYWORDS:
            if in_background:
                result["background"].append(line)
            elif current is not None:
                current["steps"].append(line)

    return result


def parse_stepdefs(path):
    """→ [{annotation, method, line}]"""
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().split("\n")
    out, pending = [], []
    for i, raw in enumerate(lines, start=1):
        m = ANNOTATION_RE.search(raw)
        if m:
            pending.append((m.group(1), i))
            continue
        if pending:
            mm = METHOD_RE.search(raw)
            if mm:
                for ann, ln in pending:
                    out.append({"annotation": ann, "method": mm.group(1), "line": ln})
                pending = []
    for ann, ln in pending:
        out.append({"annotation": ann, "method": "", "line": ln})
    return out


def load_corpus(project):
    features = find_feature_files(project)
    if not features:
        die("не найдено ни одного .feature под %s/%s — это не проект автотестов"
            % (project, FEATURE_ROOTS[0]))
    corpus = []
    for path in features:
        data = parse_feature(path)
        data["path"] = path
        data["module"] = module_of(project, path)
        corpus.append(data)
    return corpus


# ---------------------------------------------------------------------------
# describe / docs
# ---------------------------------------------------------------------------
DOC_FILES = {
    "docs/testproject.md": "карта проекта: где feature-файлы, где step definitions, какие модули",
    "docs/steps": "справочник шагов по классам step definitions",
    "docs/stashKeys.md": "ключи stash, которые кладут и читают шаги",
    "docs/tags.md": "словарь тегов с частотами",
}


def doc_status(project):
    status = {}
    for rel in DOC_FILES:
        p = os.path.join(project, rel)
        if rel.endswith(".md"):
            status[rel] = os.path.isfile(p)
        else:
            status[rel] = os.path.isdir(p) and any(
                f.endswith(".md") for f in os.listdir(p)
            )
    return status


def cmd_describe(args):
    project = args.project
    status = doc_status(project)
    missing = [k for k, ok in status.items() if not ok]

    corpus = load_corpus(project)
    stepdefs = find_stepdef_files(project)
    scenarios = sum(len(f["scenarios"]) for f in corpus)
    modules = sorted({f["module"] for f in corpus})

    print("Проект: %s" % os.path.abspath(project))
    print("Feature-файлов: %d · сценариев: %d · модулей: %d" % (len(corpus), scenarios, len(modules)))
    print("Классов step definitions: %d" % len(stepdefs))
    print("")
    print("Описание проекта:")
    for rel, descr in DOC_FILES.items():
        mark = "OK  " if status[rel] else "НЕТ "
        print("  %s %-22s %s" % (mark, rel, descr))

    if missing:
        print("")
        print("Отсутствует: %s" % ", ".join(missing))
        print("Собрать из кода: autotest-corpus.py docs")
        return 1
    return 0


def _write(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


GENERATED_HEADER = (
    "<!-- сгенерировано autotest-corpus.py из кода и feature-файлов.\n"
    "     Правки руками сохраняются: повторный запуск без --force файл не трогает. -->\n\n"
)


def gen_testproject(project, corpus, stepdefs):
    by_module = defaultdict(list)
    for f in corpus:
        by_module[f["module"]].append(f)

    out = [GENERATED_HEADER, "# Карта тестового проекта\n\n"]
    out.append("## Где что лежит\n\n")
    out.append("| Что | Где |\n|---|---|\n")
    out.append("| Feature-файлы | `%s/` |\n" % FEATURE_ROOTS[0])
    if stepdefs:
        pkgs = sorted({os.path.dirname(os.path.relpath(p, project)).replace("\\", "/")
                       for p in stepdefs})
        out.append("| Step definitions | %s |\n" % ", ".join("`%s/`" % p for p in pkgs))
    out.append("| Модулей (каталогов сценариев) | %d |\n" % len(by_module))
    out.append("| Feature-файлов | %d |\n" % len(corpus))
    out.append("| Сценариев | %d |\n\n" % sum(len(f["scenarios"]) for f in corpus))

    out.append("## Модули\n\n")
    out.append("| Модуль | Файлов | Сценариев | Преобладающие теги |\n|---|---|---|---|\n")
    for mod in sorted(by_module):
        files = by_module[mod]
        tags = Counter()
        for f in files:
            tags.update(f["tags"])
            for s in f["scenarios"]:
                tags.update(s["tags"])
        top = ", ".join("`%s`" % t for t, _ in tags.most_common(4)) or "—"
        out.append("| `%s` | %d | %d | %s |\n"
                   % (mod, len(files), sum(len(f["scenarios"]) for f in files), top))

    out.append("\n## Feature-файлы\n\n")
    for f in corpus:
        rel = os.path.relpath(f["path"], project).replace("\\", "/")
        n = len(f["scenarios"])
        out.append("- `%s` — %s (%d %s)%s\n"
                   % (rel, f["feature"] or "без заголовка", n,
                      plural(n, "сценарий", "сценария", "сценариев"),
                      " · **есть Предыстория**" if f["background"] else ""))
    return "".join(out)


def gen_steps_docs(project, corpus, stepdefs):
    """По классу на файл: аннотация, метод и пример употребления из корпуса."""
    usage = defaultdict(list)
    for f in corpus:
        for s in f["scenarios"]:
            for step in s["steps"]:
                body = step.split(" ", 1)[1] if " " in step else step
                usage[norm(body)].append(step)

    written = []
    for path in stepdefs:
        steps = parse_stepdefs(path)
        if not steps:
            continue
        cls = os.path.splitext(os.path.basename(path))[0]
        rel = os.path.relpath(path, project).replace("\\", "/")
        out = [GENERATED_HEADER, "# Шаги: %s\n\n" % cls, "Источник: `%s`\n\n" % rel]
        out.append("| Аннотация | Метод | Пример из feature-файлов |\n|---|---|---|\n")
        for st in steps:
            example = ""
            literal = re.sub(r"\{[^}]*\}|\([^)]*\)|\\[sdw]\*?|[\^$]", "", st["annotation"])
            key_words = tokens(literal)[:3]
            if key_words:
                for norm_body, samples in usage.items():
                    if all(w in norm_body for w in key_words):
                        example = samples[0]
                        break
            out.append("| `%s` | `%s` | %s |\n"
                       % (st["annotation"].replace("|", "\\|"),
                          st["method"] or "—",
                          ("`%s`" % example.replace("|", "\\|")) if example else "_(не встречался)_"))
        written.append((os.path.join(project, "docs", "steps", cls + ".md"), "".join(out)))
    return written


def gen_stash_keys(project, corpus):
    used = Counter()
    where = defaultdict(set)
    for f in corpus:
        for block, steps in (("Предыстория", f["background"]),):
            for step in steps:
                for k in STASH_USE_RE.findall(step):
                    used[k] += 1
                    where[k].add("%s (%s)" % (block, f["module"]))
        for s in f["scenarios"]:
            for step in s["steps"]:
                for k in STASH_USE_RE.findall(step):
                    used[k] += 1
                    where[k].add(f["module"])

    out = [GENERATED_HEADER, "# Ключи stash\n\n"]
    if not used:
        out.append("_В корпусе не встретилось ни одной переменной вида `#{name}`._\n")
        return "".join(out)
    out.append("Собрано по употреблению `#{...}` в feature-файлах. "
               "Ключ, встреченный только в одном модуле, скорее всего локальный.\n\n")
    out.append("| Ключ | Употреблений | Модули |\n|---|---|---|\n")
    for k, n in sorted(used.items(), key=lambda kv: (-kv[1], kv[0])):
        mods = ", ".join("`%s`" % m for m in sorted(where[k])[:5])
        out.append("| `#{%s}` | %d | %s |\n" % (k, n, mods))
    return "".join(out)


def gen_tags(project, corpus):
    tags = Counter()
    where = defaultdict(set)
    for f in corpus:
        for t in f["tags"]:
            tags[t] += 1
            where[t].add(f["module"])
        for s in f["scenarios"]:
            for t in s["tags"]:
                tags[t] += 1
                where[t].add(f["module"])

    out = [GENERATED_HEADER, "# Теги\n\n"]
    out.append("Частоты по корпусу. Тег из одного модуля — компонентный; "
               "тег из многих — сквозной (стенд, набор, очистка).\n\n")
    out.append("| Тег | Вхождений | Модулей | Где |\n|---|---|---|---|\n")
    for t, n in sorted(tags.items(), key=lambda kv: (-kv[1], kv[0])):
        mods = sorted(where[t])
        shown = ", ".join("`%s`" % m for m in mods[:4])
        if len(mods) > 4:
            shown += ", …"
        out.append("| `%s` | %d | %d | %s |\n" % (t, n, len(mods), shown))
    return "".join(out)


def is_generated(path):
    """Файл, который человек не трогал, начинается с нашего заголовка. Как только
    в нём появились правки руками, заголовок обычно снимают — и переписывать
    такой файл значит стереть чужую работу."""
    if not os.path.isfile(path):
        return False
    try:
        head = io.open(path, encoding="utf-8", errors="replace").read(len(GENERATED_HEADER) + 80)
    except OSError:
        return False
    return head.startswith(GENERATED_HEADER[:60])


def cmd_docs(args):
    project = args.project
    corpus = load_corpus(project)
    stepdefs = find_stepdef_files(project)
    status = doc_status(project)

    # --update — режим актуализации: пересобирает то, что сгенерировано нами, и
    # не трогает то, что дописал человек. --force не различает ни того ни
    # другого и потому годится только по явной просьбе.
    if args.update:
        return do_update(project, corpus, stepdefs)

    planned = []
    if args.force or not status["docs/testproject.md"]:
        planned.append((os.path.join(project, "docs/testproject.md"),
                        gen_testproject(project, corpus, stepdefs)))
    if args.force or not status["docs/stashKeys.md"]:
        planned.append((os.path.join(project, "docs/stashKeys.md"),
                        gen_stash_keys(project, corpus)))
    if args.force or not status["docs/tags.md"]:
        planned.append((os.path.join(project, "docs/tags.md"),
                        gen_tags(project, corpus)))
    if args.force or not status["docs/steps"]:
        planned.extend(gen_steps_docs(project, corpus, stepdefs))

    if not planned:
        print("Описание проекта на месте — генерировать нечего.")
        print("Пересобрать поверх: docs --force")
        return 0

    for path, text in planned:
        _write(path, text)
        print("записан: %s" % os.path.relpath(path, project).replace("\\", "/"))
    print("")
    print("Файлов записано: %d" % len(planned))
    print("Это факты из кода и корпуса, а не согласованная документация:")
    print("семантику шагов и смысл тегов дописывает человек.")
    return 0


def do_update(project, corpus_data, stepdefs):
    regenerated, kept, created = [], [], []

    def consider(rel, text):
        path = os.path.join(project, rel)
        if not os.path.exists(path):
            _write(path, text)
            created.append(rel)
        elif is_generated(path):
            _write(path, text)
            regenerated.append(rel)
        else:
            kept.append(rel)

    consider("docs/testproject.md", gen_testproject(project, corpus_data, stepdefs))
    consider("docs/stashKeys.md", gen_stash_keys(project, corpus_data))
    consider("docs/tags.md", gen_tags(project, corpus_data))
    for path, text in gen_steps_docs(project, corpus_data, stepdefs):
        consider(os.path.relpath(path, project).replace("\\", "/"), text)

    for rel in created:
        print("создан:      %s" % rel)
    for rel in regenerated:
        print("обновлён:    %s" % rel)
    for rel in kept:
        print("не тронут:   %s  (правлен руками)" % rel)
    print("")
    print("Создано %d · обновлено %d · оставлено как есть %d"
          % (len(created), len(regenerated), len(kept)))
    if kept:
        print("Файлы с ручными правками не перезаписываются. Что в них устарело —")
        print("покажет `diff`; переписать поверх — только `docs --force`.")
    return 0


# ---------------------------------------------------------------------------
# diff — что появилось в коде, а в описании ещё нет
# ---------------------------------------------------------------------------
BACKTICK_RE = re.compile(r"`([^`]+)`")
CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")


def documented_steps(project):
    """Аннотации, перечисленные в docs/steps/*.md. Берётся первая колонка
    таблицы — в неё gen_steps_docs кладёт аннотацию."""
    out = set()
    base = os.path.join(project, "docs", "steps")
    if not os.path.isdir(base):
        return out
    for name in sorted(os.listdir(base)):
        if not name.endswith(".md"):
            continue
        text = io.open(os.path.join(base, name), encoding="utf-8", errors="replace").read()
        for line in text.split("\n"):
            line = line.strip()
            if not line.startswith("|"):
                continue
            # Разрез по неэкранированным `|`: gen_steps_docs пишет аннотацию
            # с `\|` внутри, и обычный split разрубил бы шаг с чередованием
            # `(?:секунд|секунды)` пополам — он всегда выглядел бы новым.
            cells = [c.strip() for c in CELL_SPLIT_RE.split(line.strip("|"))]
            if not cells:
                continue
            m = BACKTICK_RE.search(cells[0])
            if m:
                out.add(m.group(1).replace("\\|", "|"))
    return out


def documented_tokens(project, rel):
    path = os.path.join(project, rel)
    if not os.path.isfile(path):
        return set()
    text = io.open(path, encoding="utf-8", errors="replace").read()
    return set(BACKTICK_RE.findall(text))


def cmd_diff(args):
    project = args.project
    corpus_data = load_corpus(project)
    stepdefs = find_stepdef_files(project)

    code_steps = set()
    for path in stepdefs:
        for st in parse_stepdefs(path):
            code_steps.add(st["annotation"])
    doc_steps = documented_steps(project)

    code_tags, code_keys = set(), set()
    for f in corpus_data:
        code_tags.update(f["tags"])
        for st in f["background"]:
            code_keys.update(STASH_USE_RE.findall(st))
        for s in f["scenarios"]:
            code_tags.update(s["tags"])
            for st in s["steps"]:
                code_keys.update(STASH_USE_RE.findall(st))
    doc_tags = documented_tokens(project, "docs/tags.md")
    doc_keys = {k[2:-1] for k in documented_tokens(project, "docs/stashKeys.md")
                if k.startswith("#{") and k.endswith("}")}

    new_steps = sorted(code_steps - doc_steps)
    gone_steps = sorted(doc_steps - code_steps)
    new_tags = sorted(code_tags - doc_tags)
    new_keys = sorted(code_keys - doc_keys)

    print("Проект: %s" % os.path.abspath(project))
    print("Шаги: в коде %d · в описании %d" % (len(code_steps), len(doc_steps)))
    print("Теги: в корпусе %d · в описании %d" % (len(code_tags), len(doc_tags)))
    print("Ключи stash: в корпусе %d · в описании %d" % (len(code_keys), len(doc_keys)))
    print("")

    def show(title, items, limit=20):
        if not items:
            return
        print("%s: %d" % (title, len(items)))
        for it in items[:limit]:
            print("   %s" % it)
        if len(items) > limit:
            print("   … ещё %d" % (len(items) - limit))
        print("")

    show("Шаги есть в коде, но не в описании", new_steps)
    show("Шаги есть в описании, но не в коде", gone_steps)
    show("Теги есть в корпусе, но не в описании", new_tags)
    show("Ключи stash есть в корпусе, но не в описании", new_keys)

    if not (new_steps or gone_steps or new_tags or new_keys):
        print("Описание совпадает с кодом — актуализировать нечего.")
        return 0
    print("Актуализировать: autotest-corpus.py docs --update")
    print("Файлы, правленные руками, --update не трогает — их правит человек.")
    return 1


# ---------------------------------------------------------------------------
# similar
# ---------------------------------------------------------------------------
def cmd_similar(args):
    query = (args.query or "").strip()
    if not query:
        die("пустой запрос")
    qt = tokens(query)
    if not qt:
        die("в запросе нет слов длиннее двух букв: %r" % query)

    corpus = load_corpus(args.project)
    scored = []
    for f in corpus:
        if args.exclude and f["module"] == args.exclude:
            continue
        for s in f["scenarios"]:
            name_w = re.findall(r"[\w-]+", norm(s["name"]))
            steps_w = re.findall(r"[\w-]+", norm(" ".join(s["steps"])))
            tags_w = re.findall(r"[\w-]+", norm(" ".join(s["tags"] + f["tags"])))
            hits = set()
            score = 0
            for w in qt:
                # Имя сценария весит больше: оно описывает намерение,
                # а шаг может упомянуть слово мимоходом.
                if any_match(w, name_w):
                    score += 3; hits.add(w)
                if any_match(w, steps_w):
                    score += 2; hits.add(w)
                if any_match(w, tags_w):
                    score += 1; hits.add(w)
            if score:
                scored.append({
                    "score": score, "hits": len(hits), "scenario": s,
                    "file": f, "path": os.path.relpath(f["path"], args.project).replace("\\", "/"),
                })

    if not scored:
        print("Доноров не найдено по запросу: %s" % query)
        print("Слова запроса: %s" % ", ".join(qt))
        return 1

    # Сначала по числу задетых слов запроса, потом по весу: сценарий, покрывший
    # весь запрос слабо, полезнее упомянувшего одно слово трижды.
    scored.sort(key=lambda r: (-r["hits"], -r["score"], r["path"], r["scenario"]["line"]))
    top = scored[:args.top]

    print("Запрос: %s" % query)
    print("Слова: %s" % ", ".join(qt))
    print("Найдено доноров: %d, показано %d" % (len(scored), len(top)))
    print("")
    for i, r in enumerate(top, start=1):
        s = r["scenario"]
        print("%d. [%d/%d слов] %s:%d" % (i, r["hits"], len(qt), r["path"], s["line"]))
        print("   модуль:   %s" % r["file"]["module"])
        print("   сценарий: %s" % s["name"])
        if s["tags"]:
            print("   теги:     %s" % " ".join(s["tags"]))
        print("")

    if args.print_body and top:
        best = top[0]
        print("--- сценарий-донор целиком: %s:%d ---" % (best["path"], best["scenario"]["line"]))
        if best["file"]["background"]:
            print("# Предыстория файла (выполняется перед каждым сценарием):")
            for st in best["file"]["background"]:
                print("#   %s" % st)
        for t in best["scenario"]["tags"]:
            print(t)
        print("Сценарий: %s" % best["scenario"]["name"])
        for st in best["scenario"]["steps"]:
            print("  %s" % st)
    return 0


def main():
    p = argparse.ArgumentParser(add_help=True, description=__doc__)
    p.add_argument("command", choices=["describe", "docs", "diff", "similar"])
    p.add_argument("query", nargs="?", default="")
    p.add_argument("--project", default=".")
    p.add_argument("--force", action="store_true", help="docs: перезаписать существующие")
    p.add_argument("--update", action="store_true",
                   help="docs: пересобрать только не тронутые человеком файлы")
    p.add_argument("--top", type=int, default=5, help="similar: сколько доноров показать")
    p.add_argument("--print", dest="print_body", action="store_true",
                   help="similar: напечатать лучший сценарий целиком")
    p.add_argument("--exclude", default="", help="similar: пропустить этот модуль")
    args = p.parse_args()

    if not os.path.isdir(args.project):
        die("не каталог: %s" % args.project)

    if args.command == "describe":
        return cmd_describe(args)
    if args.command == "docs":
        return cmd_docs(args)
    if args.command == "diff":
        return cmd_diff(args)
    return cmd_similar(args)


if __name__ == "__main__":
    sys.exit(main())
