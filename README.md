# NoteCraft

A clean-room native Swift notebook app for macOS and iPadOS. No third-party runtime
libraries, account system, proprietary cloud service, or AI features. Notes are portable
`.notecraft` packages; the system document browser opens files from local storage and
connected file providers, and SwiftUI manages in-place autosave.

## Build

Requires Xcode 16 or newer with Swift 6, macOS 14 / iPadOS 17 or newer.

- Open `NoteCraft.xcodeproj`, select the NoteCraft scheme and a Mac or iPad destination.
- To run on a physical device, choose your own signing team in Xcode.
- `swift test` runs the platform-independent core tests on macOS.
- `swift run NoteCraft` runs the macOS app from the Swift package.
- Optional: `xcodegen generate` regenerates the checked-in project from `project.yml`.

## Workflow

On Mac, the Notebooks window offers grid/list browsing, folders, paper templates and PDF
import. Choose a storage folder to use a connected provider; its security-scoped bookmark
is retained. Existing document windows appear in the workspace's tab strip. On iPad,
Apple's Files-backed document browser manages notebooks and folders. Save a new notebook
once to choose its provider and location; the system then manages autosave.

Select a toolbar tool; tap it again for settings. The pen supports fountain, ballpoint
and brush styles, pressure/tilt, custom colors, hex entry and three persistent thickness
presets. Erasure supports precision splits and whole strokes, with highlighter-only and
auto-deselect options. Highlighter ink renders beneath pen ink. Closed shapes support fill.
Lasso filters select handwriting, images and text, with cut/copy/paste, deletion, recoloring,
transforms, cropped PNG export and one reusable vector clip slot. Text boxes support font,
size, alignment, width, border and background; tap an existing box to edit it. Images can
be imported from Files or Photos, dropped as file URLs, moved, pinched and rotated.

The thumbnail button reveals pages and bookmarks; the plus button opens paper templates.
Use the overflow menu for page direction, import, scan, paste and input settings.
iPad scanning uses VisionKit on supported physical hardware. Read-only mode follows PDF
links. PDF import appends backgrounds with original dimensions; multi-page PDF export
retains vector ink, text and the original PDF backgrounds. Search covers text boxes.

## Architecture

- **NoteCraftCore**: Codable, Sendable notebook/page/ink types, point transforms,
  bounded-depth quadtree, lasso, erasure, shape recognition, package codec and actor I/O.
- **NoteCraft**: SwiftUI DocumentGroup/FileDocument shell, workspace and settings,
  UIKit/AppKit pointer bridge, shared CoreGraphics rendering and PDFKit import.
- **Tests**: Swift Testing coverage for package round trips and integrity, coordinate
  transforms, spatial queries, selection, erasure, concurrent conflict-safe writes,
  original PDF dimensions, searchable vector text, import and PNG rendering.

Coordinates are PDF points. Existing ink is cached in a CoreGraphics layer during input;
active samples render directly in a native view. iPad input consumes coalesced Pencil
samples with pressure and altitude. UI is main-actor isolated with Swift 6 concurrency
checking. See [the format specification](docs/FORMAT.md).

## Current boundaries

This is a working native implementation, not complete Goodnotes feature parity.
iPad uses the system document browser and separate document scenes; an in-workspace
cross-document tab manager is pending there. The Mac tab strip switches document windows.
The library currently labels files by filename rather than indexing notebook metadata.
Lasso transformations use menu commands; image transformations have direct gestures.
Text can be moved and resized through selection, but text rotation is pending. Color
changes apply to ink and text rather than recoloring image pixels. The element library
currently holds one saved handwriting clip. Shapes use geometric heuristics rather than
a trained recognition system. Horizontal mode scrolls without page snapping. Palette
slots are fixed presets plus a custom color. System autosave/export interactions retain
Apple's standard UI rather than reproducing every Goodnotes drawer and share sheet.

120 Hz latency is a design target, not a measured guarantee. The canvas requests 120 Hz
on iPad and uses coalesced/predicted Pencil samples plus cached retained page content.
Apple Pencil only mode rejects finger drawing; full palm-rejection behavior, physical
Pencil latency, large-document profiling, cloud-provider conflict UI and future format
migrations need device validation. PDF import and explicit file reads run in an actor;
PDF export and cache generation remain synchronous and may block for very large files.
SwiftUI controls document serialization/autosave scheduling. Explicit PackageStore writes
have revision conflict checks; the interactive document session relies on Apple's conflict
handling. UI automation was unavailable during development, so interactive layout and
gesture behavior still require manual QA. Core and PDF rendering tests are automated.

## Contributing

Open an issue describing a reproducible problem or proposed feature. Keep changes small,
run `swift test`, and build both platform destinations. Preserve PDF-point coordinates,
package compatibility, native APIs and clean-room provenance. Explain non-obvious
engineering decisions in comments; avoid describing self-evident syntax. Contributions
must use original code and assets, without proprietary Goodnotes source or artwork.

## License

MIT. Goodnotes is a trademark of its respective owner. NoteCraft is independent and
is not affiliated with or endorsed by Goodnotes.
