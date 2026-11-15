#!/usr/bin/env python3
"""Checks docs/appstore/<locale>/ against App Store Connect's limits before the text is pasted in.

  python3 scripts/appstore_check.py

Limits: name 30, subtitle 30, promotional text 170, keywords 100, description 4000, release notes 4000.
Also: every language the app ships has a locale folder with every field, and a keyword is not repeated
or already in the name or subtitle (Apple indexes those, so a repeat wastes characters). See docs/appstore/README.md."""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STORE = os.path.join(ROOT, "docs/appstore")
LIMITS = {"name.txt": 30, "subtitle.txt": 30, "promotional_text.txt": 170, "keywords.txt": 100,
          "description.txt": 4000, "release_notes.txt": 4000}
URLS = ["support_url.txt", "privacy_url.txt"]
# The app's languages (CFBundleLocalizations in project.yml) and the store locale each is entered under.
LOCALES = {"en": "en-US", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it"}

problems = []


def read(locale, name):
    path = os.path.join(STORE, locale, name)
    if not os.path.exists(path):
        problems.append(f"{locale}/{name}: missing")
        return None
    return open(path, encoding="utf-8").read().rstrip("\n")


for code, locale in LOCALES.items():
    texts = {}
    for name, limit in LIMITS.items():
        text = read(locale, name)
        if text is None:
            continue
        texts[name] = text
        if not text.strip():
            problems.append(f"{locale}/{name}: empty")
        if len(text) > limit:
            problems.append(f"{locale}/{name}: {len(text)} characters, the limit is {limit}")
        if re.search(r"\[[^\]]*\]|TODO|lorem", text, re.I):
            problems.append(f"{locale}/{name}: still has a placeholder")
    for name in URLS:
        url = read(locale, name)
        if url is not None and not url.startswith("https://"):
            problems.append(f"{locale}/{name}: must be an https address")
    keywords = texts.get("keywords.txt", "")
    if keywords:
        words = [w.strip().lower() for w in keywords.split(",")]
        if any(not w for w in words):
            problems.append(f"{locale}/keywords.txt: empty keyword (check the commas)")
        if len(set(words)) != len(words):
            problems.append(f"{locale}/keywords.txt: a keyword is repeated")
        if ", " in keywords:
            problems.append(f"{locale}/keywords.txt: no space after a comma (it costs a character)")
        indexed = (texts.get("name.txt", "") + " " + texts.get("subtitle.txt", "")).lower()
        for w in words:
            if w and re.search(rf"\b{re.escape(w)}\b", indexed):
                problems.append(f"{locale}/keywords.txt: '{w}' is already in the name or subtitle")

for entry in sorted(os.listdir(STORE)):
    if os.path.isdir(os.path.join(STORE, entry)) and entry not in LOCALES.values():
        problems.append(f"{entry}: a folder for a language the app does not ship")

if problems:
    print("\n".join(problems))
    sys.exit(f"{len(problems)} problem(s)")
print(f"{len(LOCALES)} locales, 0 problems")
