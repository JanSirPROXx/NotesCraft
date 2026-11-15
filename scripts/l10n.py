#!/usr/bin/env python3
"""Keeps Sources/NoteCraft/Localizable.xcstrings in step with the code and the translation table.

  python3 scripts/l10n.py sync    after a build: collect the texts the compiler found in the code
                                  (xcstringstool), then write the translations of
                                  scripts/l10n/translations.txt into the catalog
  python3 scripts/l10n.py check   verify the catalog: every text has all four languages, the
                                  placeholders (%@, %lld, ...) are the same as in the English text,
                                  and nothing in the table is unused. Exits non-zero on a problem.

Texts that need no translation (numbers, units, font names) are marked in the catalog by `sync`.
See docs/LOCALIZATION.md."""
import json, re, subprocess, sys, glob, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Sources/NoteCraft/Localizable.xcstrings")
TABLE = os.path.join(ROOT, "scripts/l10n/translations.txt")
LANGS = ["de", "fr", "es", "it"]
# Not words: nothing to translate in them.
NO_TRANSLATE = {"%@ · %@", "%@, %@", "%@ pt", "%lld", "%lld %@", "%lld pt", "36", "=", "Courier", "Georgia", "Helvetica", "NotesCraft", "OK", "PDF", "Emoji", "Apple Pencil"}
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|lf|f|@)")


def load_table():
    table, seen = {}, set()
    for number, line in enumerate(open(TABLE, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        parts = [p.replace("\\n", "\n") for p in line.split(" ‖ ")]
        if len(parts) != 5:
            sys.exit(f"{TABLE}:{number}: expected key and four translations, found {len(parts)} fields")
        key = parts[0]
        if key in seen:
            sys.exit(f"{TABLE}:{number}: duplicate key {key!r}")
        seen.add(key)
        table[key] = dict(zip(LANGS, parts[1:]))
    return table


def derived_data_stringsdata():
    # A build made with `-derivedDataPath <dir>` is named by NOTECRAFT_DERIVED_DATA; otherwise the newest of Xcode's own.
    custom = os.environ.get("NOTECRAFT_DERIVED_DATA")
    dirs = [custom.rstrip("/") + "/"] if custom else sorted(
        glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/NoteCraft-*/")), key=os.path.getmtime, reverse=True)
    if not dirs:
        sys.exit("no build found: build the NoteCraft-iPad scheme first")
    found = []
    for target in ("NoteCraft", "NoteCraftCore"):
        found += glob.glob(f"{dirs[0]}Build/Intermediates.noindex/NoteCraft.build/Debug-iphonesimulator/{target}.build/Objects-normal/*/*.stringsdata")
    return [f for f in found if "ExtractedAppShortcutsMetadata" not in f]


def sync():
    files = derived_data_stringsdata()
    subprocess.run(["xcrun", "xcstringstool", "sync", CATALOG, "--stringsdata", *files], check=True)
    catalog = json.load(open(CATALOG, encoding="utf-8"))
    table = load_table()
    # What the code no longer asks for is dropped, not kept as stale.
    catalog["strings"] = {k: v for k, v in catalog["strings"].items() if v.get("extractionState") != "stale"}
    for key, entry in catalog["strings"].items():
        if key in NO_TRANSLATE or not re.search(r"[A-Za-z]{2}", PLACEHOLDER.sub("", key)):
            entry["shouldTranslate"] = False
            entry.pop("localizations", None)
            continue
        entry.pop("shouldTranslate", None)
        if key in table:
            entry["localizations"] = {
                lang: {"stringUnit": {"state": "translated", "value": table[key][lang]}} for lang in LANGS
            }
    json.dump(catalog, open(CATALOG, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
    open(CATALOG, "a", encoding="utf-8").write("\n")
    print(f"{len(catalog['strings'])} texts in the catalog")


def check():
    catalog = json.load(open(CATALOG, encoding="utf-8"))["strings"]
    table = load_table()
    problems = []
    for key, entry in catalog.items():
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        for lang in LANGS:
            unit = localizations.get(lang, {}).get("stringUnit")
            if not unit or not unit.get("value", "").strip():
                problems.append(f"missing {lang}: {key!r}")
                continue
            if unit.get("state") != "translated":
                problems.append(f"not translated ({unit.get('state')}) {lang}: {key!r}")
            if sorted(PLACEHOLDER.findall(unit["value"])) != sorted(PLACEHOLDER.findall(key)):
                problems.append(f"placeholders differ in {lang}: {key!r} -> {unit['value']!r}")
    for key in table:
        if key not in catalog:
            problems.append(f"in the table but not in the code: {key!r}")
    for p in problems:
        print(p)
    print(f"{len(catalog)} texts, {len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    {"sync": sync, "check": check}.get(command, lambda: sys.exit(__doc__))()
