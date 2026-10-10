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

SwiftUI DocumentGroup and FileDocument own coordinated loading, autosave and security
scope in the app. PackageStore offers coordinated atomic explicit writes, with an optional
expected revision that prevents overwriting concurrent changes. No account or server is used.

Optional fields extend version 1 compatibly: pages may include `backgroundSize` for
non-standard/rotated PDF dimensions, strokes may include `fillColor`, and text boxes
may include `fontName`, `alignment`, `background`, `border` and `boxWidth`. Missing
optional fields retain default rendering. Asset paths may not traverse directories.
Invalid geometry, empty notebooks, missing media and future versions are rejected.
