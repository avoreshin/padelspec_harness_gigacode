#!/usr/bin/env python3
"""testproject-profile.py — профиль тестового проекта для команд тестировщика.

Команды `/generate-test-cases` и `/generate-autotests` написаны по одному
проекту: Java, Maven, Cucumber с русской локалью, шаги в аннотациях. Всё это
зашито в них константами, и на проекте с другим устройством они отвергают
правильный каталог либо, хуже, генерируют по несуществующим правилам.

Профиль — единственное место, где живут ответы на «где тесты», «чем
запускается», «есть ли инвентарь шагов и как он устроен». Команды читают его,
а не угадывают. Проект, который автоматика не распознала, не отвергается:
профиль пишется с пустыми полями и пометкой, что их заполняет человек, — так
обвязка работает и с проектом, о котором она ничего не знает.

Файл: `docs/test-project-profile.md` — frontmatter (контракт для скриптов) плюс
человекочитаемая часть.

Команды:
  detect  [--project DIR]                  что видно в каталоге, ничего не пишет
  init    [--project DIR] [--force]        записать профиль
  check   [--project DIR]                  профиль есть, валиден, актуален?
  refresh [--project DIR] [--apply]        дельта фактов; --apply обновляет
  show    [--project DIR] [--key K]        прочитать поле профиля

Коды возврата:
  0 — успех (check: профиль на месте и актуален)
  1 — профиля нет, он устарел либо проект не распознан
  2 — ошибка вызова
"""

import argparse
import datetime
import importlib.util
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROFILE_REL = "docs/test-project-profile.md"
SCHEMA = "test-project-profile/v1"


def die(msg, code=2):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(code)


def _load(name, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        die("не найден %s рядом с testproject-profile.py" % filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


corpus = _load("_pdls_corpus", "autotest-corpus.py")
exporter = _load("_pdls_export", "export-testcases-xml.py")

# ---------------------------------------------------------------------------
# Распознавание проекта
#
# Признак — файл или каталог, а не догадка по имени. Порядок важен: проект с
# feature-файлами и pom.xml — cucumber-jvm, хотя формально в нём есть и JUnit.
# ---------------------------------------------------------------------------
FRAMEWORKS = (
    # (ключ, язык, как выглядит, чем запускается)
    ("cucumber-jvm", "java"),
    ("cucumber-js", "javascript"),
    ("behave", "python"),
    ("pytest-bdd", "python"),
    ("pytest", "python"),
    ("junit", "java"),
    ("robotframework", "robot"),
    ("playwright", "javascript"),
    ("other", ""),
)

RUN_COMMANDS = {
    ("cucumber-jvm", "maven"): {
        "all": "mvn test",
        "by_tag": 'mvn test -Dcucumber.filter.tags="{tags}"',
        "dry_run": "mvn test -Dcucumber.execution.dry-run=true",
    },
    ("cucumber-jvm", "gradle"): {
        "all": "./gradlew test",
        "by_tag": './gradlew test -Dcucumber.filter.tags="{tags}"',
        "dry_run": "./gradlew test -Dcucumber.execution.dry-run=true",
    },
    ("junit", "maven"): {"all": "mvn test", "by_tag": "mvn test -Dtest={tags}", "dry_run": ""},
    ("junit", "gradle"): {"all": "./gradlew test", "by_tag": "./gradlew test --tests {tags}", "dry_run": ""},
    ("pytest", "pip"): {"all": "pytest", "by_tag": "pytest -k {tags}", "dry_run": "pytest --collect-only"},
    ("pytest-bdd", "pip"): {"all": "pytest", "by_tag": "pytest -k {tags}", "dry_run": "pytest --collect-only"},
    ("behave", "pip"): {"all": "behave", "by_tag": "behave --tags {tags}", "dry_run": "behave --dry-run"},
    ("cucumber-js", "npm"): {"all": "npx cucumber-js", "by_tag": 'npx cucumber-js --tags "{tags}"',
                             "dry_run": "npx cucumber-js --dry-run"},
    ("playwright", "npm"): {"all": "npx playwright test", "by_tag": "npx playwright test -g {tags}", "dry_run": ""},
    ("robotframework", "pip"): {"all": "robot tests", "by_tag": "robot --include {tags} tests", "dry_run": "robot --dryrun tests"},
}


def exists(project, *rel):
    return os.path.exists(os.path.join(project, *rel))


def find_first_dir(project, candidates):
    for c in candidates:
        if os.path.isdir(os.path.join(project, c)):
            return c
    return ""


def find_glob_dirs(project, suffix, limit=6):
    """Каталоги, в которых лежат файлы с нужным расширением."""
    out = []
    seen = set()
    base = project
    count = 0
    for dirpath, fname in corpus.walk_files(base):
        count += 1
        if not fname.endswith(suffix):
            continue
        rel = os.path.relpath(dirpath, project).replace("\\", "/")
        if rel not in seen:
            seen.add(rel)
            out.append(rel)
        if len(out) >= limit:
            break
    return out


def detect_build(project):
    if exists(project, "pom.xml"):
        return "maven"
    if exists(project, "build.gradle") or exists(project, "build.gradle.kts"):
        return "gradle"
    if exists(project, "package.json"):
        return "npm"
    for f in ("pytest.ini", "pyproject.toml", "setup.cfg", "requirements.txt", "tox.ini"):
        if exists(project, f):
            return "pip"
    return ""


def detect(project):
    """→ словарь фактов. Ничего не пишет и ничем не рискует."""
    build = detect_build(project)
    features_dir = find_first_dir(project, (
        "src/test/resources/features", "features", "src/test/features", "tests/features",
    ))
    feature_files = bool(features_dir) or bool(find_glob_dirs(project, ".feature", limit=1))
    robot_files = bool(find_glob_dirs(project, ".robot", limit=1))

    stepdefs_java = corpus.find_stepdef_files(project)

    framework, language = "other", ""
    if feature_files and (build in ("maven", "gradle") or stepdefs_java):
        # Признак — сами артефакты, а не файл сборки: проект автотестов может
        # лежать модулем без своего pom.xml, и отказ по его отсутствию отверг бы
        # правильный каталог.
        framework, language = "cucumber-jvm", "java"
    elif feature_files and build == "npm":
        framework, language = "cucumber-js", "javascript"
    elif feature_files and build == "pip":
        framework, language = ("behave", "python") if exists(project, "features/environment.py") \
            else ("pytest-bdd", "python")
    elif robot_files:
        framework, language = "robotframework", "robot"
    elif build == "pip":
        framework, language = "pytest", "python"
    elif build in ("maven", "gradle"):
        framework, language = "junit", "java"
    elif build == "npm":
        framework, language = "playwright", "javascript"

    stepdefs = stepdefs_java if language in ("java", "") else []
    stepdef_dirs = sorted({os.path.relpath(os.path.dirname(p), project).replace("\\", "/")
                           for p in stepdefs})

    tests_dir = features_dir or find_first_dir(project, ("tests", "test", "src/test/java", "e2e"))

    inventory_kind = "none"
    if framework == "cucumber-jvm" and stepdefs:
        inventory_kind = "cucumber-annotations"
    elif framework in ("cucumber-js", "behave", "pytest-bdd"):
        inventory_kind = "step-definitions"

    facts = {
        "framework": framework,
        "language": language,
        "build": build,
        "tests_dir": tests_dir,
        "features_dir": features_dir,
        "stepdef_dirs": stepdef_dirs,
        "inventory_kind": inventory_kind,
        "run": RUN_COMMANDS.get((framework, build), {"all": "", "by_tag": "", "dry_run": ""}),
    }
    facts.update(count_inventory(project, facts))
    return facts


def count_inventory(project, facts):
    """Счётчики корпуса. Пусто там, где считать нечего, — не ноль по умолчанию."""
    out = {"features": 0, "scenarios": 0, "tags": 0, "stash_keys": 0,
           "steps": 0, "step_classes": 0}
    if facts.get("features_dir"):
        try:
            files = corpus.find_feature_files(project)
        except SystemExit:
            files = []
        parsed = []
        for p in files:
            try:
                parsed.append(corpus.parse_feature(p))
            except OSError:
                continue
        out["features"] = len(parsed)
        out["scenarios"] = sum(len(f["scenarios"]) for f in parsed)
        tags, keys = set(), set()
        for f in parsed:
            tags.update(f["tags"])
            for s in f["scenarios"]:
                tags.update(s["tags"])
                for step in s["steps"]:
                    keys.update(corpus.STASH_USE_RE.findall(step))
            for step in f["background"]:
                keys.update(corpus.STASH_USE_RE.findall(step))
        out["tags"] = len(tags)
        out["stash_keys"] = len(keys)
    if facts.get("inventory_kind") == "cucumber-annotations":
        classes = corpus.find_stepdef_files(project)
        out["step_classes"] = len(classes)
        out["steps"] = sum(len(corpus.parse_stepdefs(p)) for p in classes)
    return out


# ---------------------------------------------------------------------------
# Файл профиля
# ---------------------------------------------------------------------------
def profile_path(project, out=None):
    return out or os.path.join(project, PROFILE_REL)


def resolve_root(path, root):
    """project_root записан относительно самого профиля: профиль переезжает
    вместе с репозиторием, а CWD у следующего запуска будет другим."""
    if os.path.isabs(root):
        return root
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), root))


def parse_frontmatter(path):
    """→ (dict, текст после frontmatter). Файл без frontmatter — ошибка, а не
    пустой словарь: молча принятый профиль-заглушка хуже отсутствующего."""
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        die("%s: нет frontmatter (первая строка должна быть '---')" % path)
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        die("%s: frontmatter не закрыт" % path)
    block = "\n".join(lines[1:end])
    try:
        import yaml
        data = yaml.safe_load(block) or {}
    except ImportError:
        data = exporter.MiniYaml(block, path).parse()
    if not isinstance(data, dict):
        die("%s: frontmatter не является отображением" % path)
    return data, "\n".join(lines[end + 1:])


def render(project_root, facts, note=""):
    today = datetime.date.today().isoformat()
    run = facts["run"]
    lines = [
        "---",
        "schema: %s" % SCHEMA,
        "generated_at: %s" % today,
        "generated_by: testproject-profile.py",
        "project_root: %s" % (project_root or "."),
        "framework: %s" % (facts["framework"] or ""),
        "language: %s" % (facts["language"] or ""),
        "build: %s" % (facts["build"] or ""),
        "tests_dir: %s" % (facts["tests_dir"] or ""),
        "features_dir: %s" % (facts["features_dir"] or ""),
        "step_definitions: %s" % (", ".join(facts["stepdef_dirs"]) or ""),
        "inventory_kind: %s" % facts["inventory_kind"],
        "run_all: %s" % (run.get("all") or ""),
        "run_by_tag: %s" % (run.get("by_tag") or ""),
        "run_dry: %s" % (run.get("dry_run") or ""),
        "features: %d" % facts["features"],
        "scenarios: %d" % facts["scenarios"],
        "tags: %d" % facts["tags"],
        "stash_keys: %d" % facts["stash_keys"],
        "steps: %d" % facts["steps"],
        "step_classes: %d" % facts["step_classes"],
        "---",
        "",
        "# Профиль тестового проекта",
        "",
        "Frontmatter выше — контракт: его читают `/generate-test-cases`,",
        "`/generate-autotests` и `/review-autotests`, чтобы не угадывать устройство",
        "проекта. Всё, что ниже, читает человек.",
        "",
        "## Что определилось автоматически",
        "",
        "| Что | Значение | Откуда |",
        "|---|---|---|",
        "| Фреймворк | `%s` | %s |" % (facts["framework"] or "—", framework_evidence(facts)),
        "| Сборка | `%s` | файл сборки в корне |" % (facts["build"] or "—"),
        "| Тесты | `%s` | каталог найден |" % (facts["tests_dir"] or "—"),
        "| Инвентарь шагов | `%s` | %s |" % (facts["inventory_kind"], inventory_evidence(facts)),
        "| Запуск | `%s` | по фреймворку и сборке |" % (run.get("all") or "—"),
        "",
        "## Что заполняет человек",
        "",
        "Автоматика видит раскладку каталогов, но не договорённости команды.",
        "Допиши руками и оставь — повторный `refresh` эти разделы не трогает:",
        "",
        "- **Как проверяется результат.** Через какие каналы тест видит эффект:",
        "  топик Kafka, кэш Ignite, база, REST, лог на машине. Это тот раздел,",
        "  из-за которого сценарий проверяет лог вместо топика.",
        "- **Стенды.** Какие есть, чем отличаются, какой берётся по умолчанию.",
        "- **Чего делать нельзя.** Каталоги вне регресса, запрещённые данные,",
        "  общие сущности на стенде.",
        "- **Особенности.** Всё, что не выводится из файлов: генерация данных,",
        "  очистка, порядок прогона.",
        "",
        "## Актуализация",
        "",
        "Проект живёт: появляются шаги, теги, модули. Профиль и описание",
        "устаревают молча, и генерация начинает опираться на то, чего уже нет.",
        "",
        "```",
        "/pdls:refresh-test-project        # дельта фактов и описания",
        "```",
        "",
    ]
    if note:
        lines.extend(["> %s" % note, ""])
    return "\n".join(l.rstrip() for l in lines)


def framework_evidence(facts):
    if facts["framework"] == "other":
        return "**не распознан — заполни руками**"
    if facts["features_dir"]:
        return "`%s`" % facts["features_dir"]
    return "файл сборки и раскладка тестов"


def inventory_evidence(facts):
    kind = facts["inventory_kind"]
    if kind == "cucumber-annotations":
        return "%d классов step definitions" % facts["step_classes"]
    if kind == "step-definitions":
        return "step definitions фреймворка"
    return "инвентаря шагов нет — сценарии пишутся по образцу существующих тестов"


# ---------------------------------------------------------------------------
# Команды
# ---------------------------------------------------------------------------
def print_facts(facts):
    print("Фреймворк:       %s" % (facts["framework"] or "не распознан"))
    print("Язык / сборка:   %s / %s" % (facts["language"] or "—", facts["build"] or "—"))
    print("Тесты:           %s" % (facts["tests_dir"] or "не найдены"))
    print("Step definitions: %s" % (", ".join(facts["stepdef_dirs"]) or "—"))
    print("Инвентарь шагов: %s" % facts["inventory_kind"])
    print("Запуск:          %s" % (facts["run"].get("all") or "—"))
    print("Корпус:          feature %d · сценариев %d · тегов %d · шагов %d"
          % (facts["features"], facts["scenarios"], facts["tags"], facts["steps"]))


def cmd_detect(args):
    facts = detect(args.project)
    print("Проект: %s" % os.path.abspath(args.project))
    print_facts(facts)
    if facts["framework"] == "other":
        print("")
        print("Фреймворк не распознан. Это не отказ: init запишет профиль")
        print("с пустыми полями, их заполняет человек.")
        return 1
    return 0


def cmd_init(args):
    path = profile_path(args.project, args.out)
    if os.path.exists(path) and not args.force:
        print("Профиль уже есть: %s" % path)
        print("Перезаписать: init --force · обновить факты: refresh --apply")
        return 1
    facts = detect(args.project)
    note = ""
    if facts["framework"] == "other":
        note = ("Фреймворк не распознан автоматически — поля `framework`, `run_*` "
                "и раздел «Как проверяется результат» заполняются руками.")
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    # project_root пишется относительно самого профиля, а не текущего каталога:
    # профиль переезжает вместе с репозиторием, а CWD у следующего запуска будет
    # другим.
    root = args.project_root
    if not root:
        root = os.path.relpath(os.path.abspath(args.project),
                               os.path.dirname(os.path.abspath(path))) or "."
        root = root.replace("\\", "/")
    io.open(path, "w", encoding="utf-8").write(render(root, facts, note))
    print("записан: %s" % path)
    print_facts(facts)
    if note:
        print("")
        print(note)
    return 0


def profile_or_die(project, out=None):
    path = profile_path(project, out)
    if not os.path.isfile(path):
        return path, None
    data, _rest = parse_frontmatter(path)
    return path, data


def cmd_check(args):
    path, data = profile_or_die(args.project, args.out)
    if data is None:
        print("Профиля нет: %s" % path)
        print("Создать: testproject-profile.py init --project <путь к тестовому проекту>")
        return 1
    if data.get("schema") != SCHEMA:
        print("Профиль другой версии: schema=%s, ожидалась %s" % (data.get("schema"), SCHEMA))
        return 1

    root = str(data.get("project_root") or ".")
    resolved = resolve_root(path, root)
    print("Профиль:      %s" % path)
    print("project_root: %s" % root)
    if not os.path.isdir(resolved):
        print("")
        print("❌ Каталог тестового проекта не существует: %s" % resolved)
        print("Поправь project_root в профиле либо пересоздай: init --force")
        return 1

    facts = detect(resolved)
    stale = []
    for key in ("features", "scenarios", "tags", "steps", "step_classes"):
        was = data.get(key)
        try:
            was = int(was)
        except (TypeError, ValueError):
            continue
        now = facts[key]
        if was != now:
            stale.append((key, was, now))
    print("Фреймворк:    %s" % (data.get("framework") or "—"))
    print("Записано:     feature %s · сценариев %s · тегов %s · шагов %s"
          % (data.get("features"), data.get("scenarios"), data.get("tags"), data.get("steps")))
    if not stale:
        print("")
        print("✅ Профиль актуален.")
        return 0
    print("")
    print("⚠ Профиль разошёлся с проектом:")
    for key, was, now in stale:
        print("   %-13s было %s → стало %s" % (key, was, now))
    print("")
    print("Актуализировать: /pdls:refresh-test-project")
    return 1


def cmd_refresh(args):
    path, data = profile_or_die(args.project, args.out)
    if data is None:
        print("Профиля нет: %s" % path)
        print("Создать: testproject-profile.py init --project <путь>")
        return 1
    root = str(data.get("project_root") or ".")
    resolved = resolve_root(path, root)
    if not os.path.isdir(resolved):
        print("❌ Каталог тестового проекта не существует: %s" % resolved)
        return 1

    facts = detect(resolved)
    changed = []
    for key in ("framework", "build", "tests_dir", "inventory_kind"):
        was = str(data.get(key) or "")
        now = str(facts[key] or "")
        if was != now:
            changed.append((key, was or "—", now or "—"))
    for key in ("features", "scenarios", "tags", "stash_keys", "steps", "step_classes"):
        try:
            was = int(data.get(key))
        except (TypeError, ValueError):
            was = None
        now = facts[key]
        if was is None or was != now:
            changed.append((key, "—" if was is None else str(was), str(now)))

    print("Профиль: %s" % path)
    if not changed:
        print("Расхождений нет — профиль актуален.")
        return 0
    print("")
    print("Дельта фактов:")
    for key, was, now in changed:
        print("   %-15s %s → %s" % (key, was, now))
    if not args.apply:
        print("")
        print("Ничего не записано. Применить: refresh --apply")
        print("Описание шагов и тегов проверяется отдельно: autotest-corpus.py diff")
        return 1

    text = io.open(path, encoding="utf-8").read()
    _data, rest = parse_frontmatter(path)
    head = render(root, facts).split("\n---\n", 1)[0]
    io.open(path, "w", encoding="utf-8").write(head + "\n---\n" + rest.lstrip("\n"))
    print("")
    print("обновлён frontmatter: %s" % path)
    print("Человеческие разделы сохранены как были (%d символов)." % len(rest))
    return 0


def cmd_show(args):
    path, data = profile_or_die(args.project, args.out)
    if data is None:
        print("Профиля нет: %s" % path)
        return 1
    if args.key:
        if args.key not in data:
            print("В профиле нет поля %s" % args.key)
            return 1
        print(data[args.key])
        return 0
    for k in sorted(data):
        print("%s: %s" % (k, data[k]))
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("command", choices=("detect", "init", "check", "refresh", "show"))
    ap.add_argument("--project", default=".", help="каталог тестового проекта (detect/init) "
                                                   "или каталог с профилем (check/refresh/show)")
    ap.add_argument("--project-root", default="", help="что записать в project_root профиля")
    ap.add_argument("--out", default="", help="путь к файлу профиля")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--key", default="")
    args = ap.parse_args()
    args.out = args.out or None

    if not os.path.isdir(args.project):
        die("каталог не найден: %s" % args.project)

    return {
        "detect": cmd_detect,
        "init": cmd_init,
        "check": cmd_check,
        "refresh": cmd_refresh,
        "show": cmd_show,
    }[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
