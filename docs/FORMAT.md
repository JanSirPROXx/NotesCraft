# NoteCraft package format, version 1

A `.notecraft` document is a directory containing `manifest.json` and `assets/`.
The manifest has `version: 1` and a `notebook` object. Notebook and page IDs are UUIDs.
Coordinates and thickness are PDF points, independent of screen scale. A4 is 595 × 842;
Letter is 612 × 792. Landscape swaps the dimensions. Each stroke stores an ordered
array of samples plus color, tool, pen style and width. A stroke's `samples` is one Base64 string of packed 12-byte little-endian records, so a page with hundreds of thousands of samples opens and saves quickly: `x` and `y` as Int32 in hundredths of a point, `pressure` as UInt16 in thousandths, `altitude` as UInt16 in ten-thousandths of a radian. The app keeps samples on exactly that grid, so nothing is lost on a save. Files from earlier builds that list each sample as `[x, y, pressure, altitude]`, or as `{"point":{"x":…,"y":…},"pressure":…,"altitude":…}`, are still read. Fountain strokes may carry an optional `tip` object (`sharpness`, `pressure`, `flatness`, each 0–1) that fixes their nib behaviour; strokes without it render with the default tip. A stroke's `style` is `fountain`, `ballpoint`, `brush` or `pencil`. Pencil ink gets its texture from a fixed grain tile laid out from the page origin, so a pencil stroke carries no data beyond its samples.
Highlighter strokes render before ink. Pages contain text boxes, image frames, bookmark
state, paper settings and optional PDF asset filename plus zero-based page index.
Assets have flat, validated filenames. Missing referenced assets and unsupported versions
are rejected rather than silently discarded. Revision is incremented on document edits.

VaultController retains the chosen folder security scope and schedules autosave.
PackageStore coordinates atomic package writes, checking the expected revision.
VaultFiles coordinates ordinary PDF/Markdown reads and atomic writes, checking a SHA-256
fingerprint to reject external changes. No account or server is used.

Optional fields extend version 1 compatibly: pages may include `backgroundSize` for
non-standard/rotated PDF dimensions, strokes may include `fillColor`, and text boxes
may include `fontName`, `alignment`, `background`, `border`, `boxWidth` and `rotation`. Missing
optional fields retain default rendering. Asset paths may not traverse directories.
Invalid geometry, empty notebooks, missing media and future versions are rejected.

Calculator pen ([`CALCULATOR.md`](CALCULATOR.md)): a stroke written with it is stored as an ordinary `pen` stroke plus `calculator: true`, and the result is an ordinary text box that may carry a `calculation` object (`strokeIDs`, the canonical `expression`, `state` `done` or `uncertain`, `recognizerVersion`). Earlier builds ignore both keys, so they show the ink as a normal pen and the result as plain text. A stored result is never recomputed on open.

Notebook `kind` optionally identifies `notebook` or `whiteboard`; absent values are paged
notebooks. Optional `viewport` retains whiteboard scale and offset. Whiteboard coordinates can extend beyond the initial background dimensions.

For an annotated PDF, the adjacent hidden `.filename.pdf.notecraft` package contains the
original PDF background plus editable objects. Its `assets/source.sha256` stores the digest
of the last saved PDF. The session trusts the sidecar only when that digest matches the
current PDF; otherwise it imports the externally modified PDF afresh. The original file
contains standard PDF annotations for use in other applications. PDF and sidecar writes
are individually atomic, with no multi-file transaction guarantee.

Text rotation is stored in radians around the layout box center; absent values mean zero.
Named elements live in the app support directory as `Elements.json`, independently of vaults.
Each element stores selected objects and required image bytes. Insertion allocates fresh
object identifiers and asset filenames so existing vault media is never replaced.

The vault-local hidden `.notecraft-trash` directory contains UUID folders. Each has an
`info.json` with original relative path and deletion date, plus the original file/package
and an adjacent PDF sidecar when present. Restore checks vault containment and refuses
collisions. Trash is not automatically purged. Moving a file and sidecar uses coordinated
operations with rollback on ordinary errors; a provider failure or crash can still require
recovery. Hidden Obsidian folders are not listed or rewritten by connecting a vault.
