#!/usr/bin/env python3
"""Adds packs to the NotesCraft catalog and checks it.

    python3 scripts/catalog.py add my-pack/     build catalog/packs/<id>.ncpack, copy the preview, update index.json
    python3 scripts/catalog.py check            check the whole catalog (what the tests and the app check, in short)

A pack folder holds:

    entry.json     id, kind, name, author, summary, category, tags, version, license (and pages for notebooks)
    preview.png    a picture of the pack (png or jpg, up to 300 KB)
    content/       what the kind of pack is made of (see docs/MARKETPLACE.md)

Only the Python standard library is used. The zip is made the same way the app makes it (sorted paths,
fixed dates), so building a pack twice gives the same bytes.
"""

import hashlib
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "catalog"

KINDS = ("theme", "sticker", "template", "planner")
CATEGORIES = ("home", "work", "study", "life")
MAX_PACK_BYTES = 25 * 1024 * 1024
MAX_PREVIEW_BYTES = 300 * 1024
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{2,63}$")
THEME_EXTENSIONS = {".json", ".ttf", ".otf", ".png", ".jpg", ".jpeg", ".pdf", ".svg"}


class Problem(Exception):
    pass


def fail(entry_id, why):
    raise Problem(f"{entry_id}: {why}")


def check_entry(entry):
    """The fields every entry needs, with the limits the app enforces."""
    i = entry.get("id", "?")
    if not isinstance(i, str) or not ID_PATTERN.match(i):
        fail(i, "the id is not 3 to 64 lowercase letters, digits, dots, dashes and underscores")
    if entry.get("kind") not in KINDS:
        fail(i, f"kind is one of {', '.join(KINDS)}")
    if entry.get("category") not in CATEGORIES:
        fail(i, f"category is one of {', '.join(CATEGORIES)}")
    if not (1 <= len(str(entry.get("name", "")).strip()) <= 60):
        fail(i, "the name is empty or over 60 characters")
    if len(str(entry.get("author", ""))) > 60:
        fail(i, "the author is over 60 characters")
    if len(str(entry.get("summary", ""))) > 400:
        fail(i, "the summary is over 400 characters")
    tags = entry.get("tags", [])
    if len(tags) > 8 or not all(1 <= len(t) <= 24 for t in tags):
        fail(i, "tags: at most 8 of 1 to 24 characters")
    if not (1 <= len(str(entry.get("version", ""))) <= 24):
        fail(i, "the version is empty or over 24 characters")
    if not (1 <= len(str(entry.get("license", ""))) <= 40):
        fail(i, "the license is empty or over 40 characters")
    if entry["kind"] in ("template", "planner"):
        pages = entry.get("pages")
        if not isinstance(pages, int) or not (1 <= pages <= 500):
            fail(i, "templates and planners say how many pages they have (pages)")
    elif "pages" in entry:
        fail(i, "only templates and planners have pages")


def read_index():
    path = CATALOG / "index.json"
    if not path.exists():
        return {"format": 1, "updated": "", "packs": []}
    index = json.loads(path.read_text(encoding="utf-8"))
    if index.get("format") != 1:
        raise Problem("index.json has a format this script does not know")
    return index


def write_index(index):
    index["packs"] = sorted(index["packs"], key=lambda e: e["id"])
    # The same layout the app writes, so a change shows as a small diff.
    text = json.dumps(index, indent=2, sort_keys=True, separators=(",", " : "), ensure_ascii=False)
    (CATALOG / "index.json").write_text(text + "\n", encoding="utf-8")


def zip_bytes(files):
    """A zip of {path: bytes}: sorted, fixed date, deflate only when it is smaller."""
    import io

    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as archive:
        for path in sorted(files):
            data = files[path]
            info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.flag_bits |= 0x800
            compressed = zlib_deflate(data)
            if data and compressed is not None and len(compressed) < len(data):
                info.compress_type = zipfile.ZIP_DEFLATED
            else:
                info.compress_type = zipfile.ZIP_STORED
            archive.writestr(info, data)
    return out.getvalue()


def zlib_deflate(data):
    import zlib

    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def collect_content(folder, kind, entry):
    """The files of `content/`, checked for the kind of pack."""
    content = {}
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            fail(entry["id"], f"{path.relative_to(folder)} is a link")
        if path.is_file():
            relative = path.relative_to(folder).as_posix()
            if any(part.startswith(".") for part in relative.split("/")):
                continue  # .DS_Store and the like
            content[relative] = path.read_bytes()
    if not content:
        fail(entry["id"], "content/ is empty")
    i = entry["id"]
    if kind == "theme":
        if "theme.json" not in content:
            fail(i, "a theme needs content/theme.json")
        for path in content:
            if Path(path).suffix.lower() not in THEME_EXTENSIONS:
                fail(i, f"{path}: a theme may only hold json, fonts, images and pdf")
        theme = json.loads(content["theme.json"])
        if theme.get("id") != i:
            fail(i, f"theme.json has the id {theme.get('id')!r}; it has to be {i!r}")
    elif kind == "sticker":
        if sorted(content) != ["elements.json"]:
            fail(i, "stickers are exactly content/elements.json")
        clips = json.loads(content["elements.json"])
        if not isinstance(clips, list) or not (1 <= len(clips) <= 200):
            fail(i, "a sticker pack holds 1 to 200 stickers")
    else:
        if "manifest.json" not in content:
            fail(i, "notebooks need content/manifest.json (a notebook package exported from the app)")
        for path in content:
            if path != "manifest.json" and not (path.startswith("assets/") and path.count("/") == 1):
                fail(i, f"{path}: only manifest.json and assets/<file> are allowed")
        notebook = json.loads(content["manifest.json"]).get("notebook", {})
        pages = len(notebook.get("pages", []))
        if pages != entry["pages"]:
            fail(i, f"the entry says {entry['pages']} pages, the notebook has {pages}")
    return content


def add(folder):
    folder = Path(folder)
    entry = json.loads((folder / "entry.json").read_text(encoding="utf-8"))
    check_entry(entry)
    i, kind = entry["id"], entry["kind"]
    content = collect_content(folder / "content", kind, entry)

    manifest = {"format": 1, "id": i, "kind": kind, "name": entry["name"], "version": entry["version"]}
    files = {"pack.json": (json.dumps(manifest, indent=2, sort_keys=True, separators=(",", " : ")) + "\n").encode()}
    for path, data in content.items():
        files["content/" + path] = data
    data = zip_bytes(files)
    if len(data) > MAX_PACK_BYTES:
        fail(i, "the pack is over 25 MB")

    preview_source = next((folder / n for n in ("preview.png", "preview.jpg") if (folder / n).exists()), None)
    if preview_source is None:
        fail(i, "there is no preview.png")
    preview = preview_source.read_bytes()
    if len(preview) > MAX_PREVIEW_BYTES:
        fail(i, "the preview is over 300 KB")
    preview_path = f"previews/{i}{preview_source.suffix.lower()}"

    (CATALOG / "packs").mkdir(parents=True, exist_ok=True)
    (CATALOG / "previews").mkdir(parents=True, exist_ok=True)
    (CATALOG / "packs" / f"{i}.ncpack").write_bytes(data)
    (CATALOG / preview_path).write_bytes(preview)

    entry.update(
        {
            "file": f"packs/{i}.ncpack",
            "preview": preview_path,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
    )
    entry.setdefault("tags", [])
    index = read_index()
    index["packs"] = [e for e in index["packs"] if e["id"] != i] + [entry]
    write_index(index)
    print(f"added {i} ({len(data)} bytes, sha256 {entry['sha256'][:12]}…)")


def check():
    index = read_index()
    seen = set()
    for entry in index["packs"]:
        check_entry(entry)
        i = entry["id"]
        if i in seen:
            fail(i, "listed twice")
        seen.add(i)
        pack = CATALOG / entry["file"]
        if not pack.exists():
            fail(i, f"{entry['file']} is missing")
        data = pack.read_bytes()
        if len(data) != entry["size"]:
            fail(i, f"size is {len(data)}, the index says {entry['size']}")
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            fail(i, "the hash is not the index's")
        if "preview" in entry and not (CATALOG / entry["preview"]).exists():
            fail(i, f"{entry['preview']} is missing")
        with zipfile.ZipFile(pack) as archive:
            names = archive.namelist()
            if "pack.json" not in names:
                fail(i, "there is no pack.json")
            for name in names:
                if name != "pack.json" and not name.startswith("content/"):
                    fail(i, f"{name} is outside content/")
                if name.startswith("/") or ".." in name.split("/"):
                    fail(i, f"{name} is not a safe path")
            manifest = json.loads(archive.read("pack.json"))
            for field in ("id", "kind", "version"):
                if manifest.get(field) != entry[field]:
                    fail(i, f"pack.json {field} is {manifest.get(field)!r}, the entry's is {entry[field]!r}")
    listed = {Path(e["file"]).name for e in index["packs"]}
    for path in (CATALOG / "packs").glob("*.ncpack"):
        if path.name not in listed:
            raise Problem(f"{path.name} is not in the index")
    print(f"{len(index['packs'])} packs are fine")


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "add":
            add(argv[2])
        elif len(argv) == 2 and argv[1] == "check":
            check()
        else:
            print(__doc__)
            return 2
    except Problem as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
