# NoteCraft package format, version 1

A `.notecraft` document is a directory containing `manifest.json` and `assets/`.
The manifest has `version: 1` and a `notebook` object. Notebook and page IDs are UUIDs.
Coordinates and thickness are PDF points, independent of screen scale. A4 is 595 × 842;
Letter is 612 × 792. Landscape swaps the dimensions. Each stroke stores an ordered
array of position, pressure, and altitude samples plus color, tool, pen style and width.
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
may include `fontName`, `alignment`, `background`, `border` and `boxWidth`. Missing
optional fields retain default rendering. Asset paths may not traverse directories.
Invalid geometry, empty notebooks, missing media and future versions are rejected.

Notebook `kind` optionally identifies `notebook` or `whiteboard`; absent values are paged
notebooks. Optional `viewport` retains whiteboard scale and offset. Whiteboard coordinates can extend beyond the initial background dimensions.

For an annotated PDF, the adjacent hidden `.filename.pdf.notecraft` package contains the
original PDF background plus editable objects. Its `assets/source.sha256` stores the digest
of the last saved PDF. The session trusts the sidecar only when that digest matches the
current PDF; otherwise it imports the externally modified PDF afresh. The original file
contains standard PDF annotations for use in other applications. PDF and sidecar writes
are individually atomic, with no multi-file transaction guarantee.
