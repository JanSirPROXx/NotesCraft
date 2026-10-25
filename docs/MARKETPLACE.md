# The marketplace

NotesCraft has a free community catalog of **themes**, **stickers**, **page templates** and
**planners**. There is no server, no account and nothing to pay: the catalog is a folder of files in
this repository (`catalog/`), the app downloads from it over HTTPS, and anyone can add a pack with a
pull request.

```
catalog/
  index.json                 every pack, with its size and SHA-256
  packs/<id>.ncpack          the packs (zip files)
  previews/<id>.png          a picture of each
```

The app reads `https://raw.githubusercontent.com/JanSirPROXx/NotesCraft/main/catalog/` by default
(Settings → Marketplace can point it somewhere else) and ships a copy of the starter packs, so the
marketplace works without a network.

## What a pack can be

| Kind       | It holds                                  | Installing it                                  |
| ---------- | ----------------------------------------- | ---------------------------------------------- |
| `theme`    | a theme folder, see [THEMES.md](THEMES.md) | adds it to Settings → Appearance               |
| `sticker`  | a list of elements                        | adds them to the element library of the toolbar |
| `template` | one or more pages                         | offered by *New page* → *Templates*; adds the pages to the notebook you are in |
| `planner`  | a whole notebook (up to 400 pages)        | *Use* creates a new notebook from it           |

A pack never holds code. A theme changes colors, fonts, icons and shapes only; templates, planners
and stickers are pages and ink.

## The pack file

A `.ncpack` is a zip file with a `pack.json` and the content in `content/`:

```
pack.json                    {"format": 1, "id": "…", "kind": "…", "name": "…", "version": "1.0"}
content/…                    what the kind is made of
```

- **theme**: `content/theme.json` and optionally `content/fonts/…`, `content/icons/…`. The id in
  `theme.json` has to be the pack's id.
- **sticker**: exactly `content/elements.json`: a JSON list of elements (`id`, `title`, `content` a
  page of strokes, text and shapes). 1 to 200 stickers; each needs a name.
- **template** / **planner**: a notebook package: `content/manifest.json` and
  `content/assets/<file>` for images and PDFs. Templates have up to 50 pages, planners up to 400.
  The easiest way to make one is to make the pages in NotesCraft, export the notebook (a
  `.notecraft` folder) and copy its `manifest.json` and `assets/` over.

Limits the app enforces, whatever the pack says about itself: at most 25 MB per pack, 25 MB per file
and 60 MB unpacked, at most 600 files; no encryption, zip64 or links; paths have to be plain, relative
and inside `content/`. A pack that breaks one is not installed.

## The index

`index.json` is what the app trusts. For every pack it lists the id, kind, name, author, summary,
category (`home`, `work`, `study` or `life`), tags, version, license, the paths of the pack and its
preview, and the pack's **size** and **SHA-256**. The app checks both before it opens a download, so a
pack that was changed after it was reviewed does not install.

## Adding a pack

1. Make a folder:

   ```
   my-pack/
     entry.json
     preview.png            a picture of the pack, up to 300 KB
     content/…
   ```

   `entry.json`:

   ```json
   {
     "id": "yourname.template.lecture-notes",
     "kind": "template",
     "name": "Lecture Notes",
     "author": "Your Name",
     "summary": "Two columns and a summary box for a lecture.",
     "category": "study",
     "tags": ["lecture", "notes"],
     "version": "1.0",
     "license": "CC0-1.0",
     "pages": 1
   }
   ```

   The id is 3 to 64 lowercase letters, digits, dots, dashes and underscores. Use your own name or
   handle as the first part so ids do not collide; `free.` is for the starter packs.
   `pages` is only for templates and planners, and has to be the number of pages in the notebook.

2. Run the script from the root of the repository:

   ```sh
   python3 scripts/catalog.py add my-pack/
   python3 scripts/catalog.py check
   ```

   `add` builds `catalog/packs/<id>.ncpack` (the same bytes every time for the same input), copies the
   preview and updates `catalog/index.json`. `check` looks at the whole catalog.

3. Run `swift test` (the tests in `RepositoryCatalogTests` open every pack the way the app does).
4. Open a pull request. It should change only the files of your pack and `index.json`.

By adding a pack you say you made it, or may share it, under the license you name. Use a license that
lets everyone use the pack for free (`CC0-1.0`, `CC-BY-4.0`, `MIT`, …). Packs with other people's
artwork, fonts or trademarks will not be accepted.

## The starter packs

The packs with ids starting `free.` are made by code: `Tests/NoteCraftTests/StarterCatalog.swift`.
To change one, edit the generator and run

```sh
NOTECRAFT_BUILD_CATALOG=1 swift test --filter buildTheStarterCatalog
```

which rewrites `catalog/` (the output is deterministic, so a change in the diff is a change in the
packs).

## Where the app keeps things

- The last catalog it downloaded, so the marketplace opens at once and works without a network.
- What is installed (`Marketplace/installed.json`) and what you saved to look at later.
- Installed templates, as notebooks, in `Marketplace/Templates/`. Themes and stickers go where
  themes and the element library already are.

Removing a pack takes away what it installed. Notes you made with a template or a planner are yours
and stay.
