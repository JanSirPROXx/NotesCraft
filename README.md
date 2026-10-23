# NotesCraft

A clean-room native Swift notebook app for iPad and Apple Pencil. No third-party runtime
libraries, account system, proprietary cloud service, or AI features. Notes are portable
`.notecraft` packages, alongside ordinary PDFs and Markdown files. Choose a storage folder
on launch, including an existing Obsidian vault or a connected file provider.

<img src="docs/screenshots/new-menu.png" width="760" alt="NotesCraft Documents library and New menu on iPad">

## Build

Requires Xcode 16 or newer with Swift 6, macOS 14 / iPadOS 17 or newer.

- Open `NoteCraft.xcodeproj`, select the NoteCraft-iPad scheme and an iPad destination.
- To run on a physical device, choose your own signing team in Xcode.
- `swift test` runs core, rendering and vault integration tests on macOS (the package builds there only as a test host; the app itself is iPad only).
- The `NoteCraft-iPad` scheme runs the folder-picker, drawing and whiteboard UI test on an iPad simulator.
- Optional: `xcodegen generate` regenerates the checked-in project from `project.yml`.

## Workflow

On both Mac and iPad, choose a storage folder first. The Documents library shows the
folder's existing files and subfolders, with a dark sidebar, favorites, search, grid/list
views and document previews. Each item has a visible actions menu for rename, move,
duplicate and Move to Trash. Breadcrumbs navigate parent folders; sorting and grid/list
choice persist. Trash stores files and folders inside `.notecraft-trash` in the selected
vault. Restore returns an item to its original path and refuses to replace existing files.
Permanent deletion and Empty Trash have confirmation dialogs. Moving a PDF also moves
its editable sidecar; open sessions and favorites follow renamed/moved paths. New creates notebooks, whiteboards, Markdown documents or
folders in the current directory; Import copies files into that directory. A remembered
folder can be opened explicitly on the next launch. Connecting a vault does not import,
convert or rewrite its existing files.

Open PDFs to annotate the original file. Autosave writes standard PDF ink and text
annotations, preserving existing annotations. A hidden adjacent `.filename.pdf.notecraft`
package keeps the original background and editable NoteCraft objects; a SHA-256 digest
invalidates it if another app changes the PDF. Markdown edits save UTF-8 directly to the
original `.md` file, preserving wiki links as text. Markdown preview uses Apple's Markdown
renderer, rather than Obsidian-specific plugins. Opening an image creates a separate
editable notebook, preserving the image file.

By default only Apple Pencil draws; one finger scrolls notebooks or pans whiteboards.
Fingers still operate everything else: tap tools and objects, and drag an existing lasso selection (or its resize/rotate handles). Finger drawing can be enabled explicitly in the overflow menu. The first Pencil contact
restores Pencil-only ink; fingers then navigate. Pencil owns its active stroke, other contacts cannot replace it,
and scrolling/pinch gestures are suspended while the Pencil is down. Broad direct
contacts are filtered. Disable Apple Pencil only in the overflow menu to draw with fingers. Without Pencil-only mode, two fingers scroll while drawing; one finger scrolls in
read-only mode. Double-tap a supported Pencil to switch between the eraser and the previous
tool.

Draw a shape and hold the tip still for about 0.45 seconds to clean it up: lines, circles and
ellipses, rectangles, diamonds, triangles, right angles, arrows (shaft plus two barbs in one
stroke), arcs and half circles, and any open or closed polyline, which keeps its corners and
straightens its sides. A smooth curve (a graph, an S-bend, a curved arrow with its head drawn in
the same stroke) becomes a clean spline through your path: jitter is averaged out, peaks and end
points stay where you drew them. Handwriting, loops and sharp zigzags are left alone. Continue dragging before lifting to
resize the shape; closed shapes retain their center. Scribble back and forth over handwriting
with the pen to erase it in one undoable step. The scribble sweeps out a zone whose reach follows
how tightly it was drawn: a small scrub is precise, a big loose one also catches ink it did not
quite touch. A stroke is erased whole, from pen down to pen up, never in pieces: one with at
least 80 % of its length inside the zone goes, and so does a longer line (a wire, an underline)
that was scribbled over on several sweeps. The ink that will go turns
red while you scribble. A loose scribble across nothing but long lines stays ink, so a symbol
drawn over a wire is not mistaken for an eraser gesture. After an uncertain case a "Keep as ink"
button appears for a few seconds; the overflow menu sets the hint to Off, When unsure or Always.
Both gestures can be disabled in the overflow menu. Circle to lasso: draw a loop around ink with the pen as usual, lift, then hold the pen still on the loop for about half a second; the loop turns into a lasso selection of what it encloses and touches (the loop itself leaves the page), and the pen returns once the selection is dismissed. A circle around a word stays a circle unless it is held; the overflow menu switches the gesture off. The eraser shows its reach as a ring that follows the pencil (and hovers with it on
supported iPads), and it sweeps the path between samples so a quick swipe leaves nothing
behind. Lasso handwriting, images and text, then drag inside the selection to
move the group with a live preview; release commits one undoable change.

Notebooks scroll vertically by default, like Goodnotes, and pinching zooms the whole document
(50 % to 600 %) around your fingers, so every page is at the same zoom. The editor menu switches to
horizontal pages: a swipe then settles on exactly one page, and swiping past the last page turns the
blank page waiting there into a real one with the previous page's paper, orientation and
dimensions; undo removes it. At the bottom of a vertical notebook, pull upward beyond the end and
hold for a moment to append the same kind of page. Opening or closing the page sidebar, rotating the
iPad or entering Split View keeps the page and the place on it. In finger-drawing mode use
two fingers; with Pencil-only or read-only mode use one finger. On Mac, continue scrolling
downward at the end with the trackpad. The new page retains
the format but does not duplicate PDF content. Whiteboards support finger pan and two-finger
pinch zoom on iPad (pan uses two fingers unless Pencil-only mode is enabled), and trackpad scrolling/magnification on Mac. Whiteboard export fits the
content, including objects outside the initial page area. Open documents appear in the
workspace tab strip on both platforms. Changes autosave after a short pause and when
returning to the library. Failed saves keep changes in memory and show an error; concurrent
external changes are rejected instead of overwritten.

Select a toolbar tool; tap it again for settings. The pen supports fountain, ballpoint,
brush and pencil styles (the pencil is graphite with a paper grain that stays fixed to the page, wider when pressed harder or laid on its side), pressure/tilt, fountain tip sharpness, pressure sensitivity and flatness with a live
preview, stroke stabilization, custom colors, hex entry and three persistent thickness
presets. Erasure supports precision splits and whole strokes, with highlighter-only and
auto-deselect options. Highlighter ink renders beneath pen ink. Closed shapes support fill.
Lasso filters select handwriting, images and text, with cut/copy/paste, deletion, recoloring,
direct corner resize and rotation handles, cropped PNG export and a named reusable element
library. Elements preserve handwriting, images and rotated text across notebooks and vaults. Text boxes support font,
size, alignment, width, border and background; with the text tool, touch a box to select it and drag it to move it; its handles widen, scale and rotate it, a tap on the selected box edits it, and a tap beside it lets go. Images can
be imported from Files or Photos, dropped as file URLs, moved, pinched and rotated.

Infinite scrolling (overflow menu, off by default) turns a notebook into one continuous vertical
sheet: pages join without gaps, and a blank page is quietly appended below as soon as the last
page holds anything, so writing never runs out of room. Page zoom is disabled in this mode.

The thumbnail button reveals pages and bookmarks; its context menu inserts, duplicates,
reorders and deletes pages. Horizontal navigation snaps to one page. The plus button opens paper templates.
Use the overflow menu for page direction, import, scan, paste, PDF forms and input settings.
Navigate document opens a page-number jump, bookmarks and a PDF table of contents.
PDF export retains outlines and remaps internal links after page reordering; links to
removed pages are disabled. Export current page creates a separate one-page PDF.
Fill PDF forms edits text fields, choices and checkboxes on the current page as an undoable
change. Read-only fields, radio buttons and signatures are not edited.
Password-protected PDFs prompt for a password and create an unlocked working PDF copy,
leaving the encrypted original unchanged. Passwords are not stored.
iPad scanning uses VisionKit on supported physical hardware. Read-only mode follows PDF
links. PDF import appends backgrounds with original dimensions; multi-page PDF export
retains vector ink, text and the original PDF backgrounds. Search covers text boxes and embedded PDF text, with page results and highlighted matches.

<img src="docs/screenshots/trash.png" width="760" alt="Recoverable trash with Restore and Undo on iPad">

## Architecture

- **NoteCraftCore**: Codable, Sendable notebook/page/ink types, point transforms,
  bounded-depth quadtree, lasso, erasure, shape recognition, package codec and actor I/O.
- **NoteCraft**: SwiftUI folder library and observable document sessions, workspace and settings,
  UIKit/AppKit pointer bridge, shared CoreGraphics rendering and PDFKit import.
- **Tests**: Swift Testing coverage for package round trips and integrity, coordinate
  transforms, spatial queries, selection, erasure, concurrent conflict-safe writes,
  original PDF dimensions, searchable vector text, import and PNG rendering.

Coordinates are PDF points. A page in the notebook is drawn as tiles at the density it is seen
at, whiteboards cache existing ink in one CoreGraphics layer; active samples render directly in
a native view. iPad input consumes coalesced Pencil
samples with pressure and altitude. UI is main-actor isolated with Swift 6 concurrency
checking. See [the format specification](docs/FORMAT.md).

## Current boundaries

The app implements the local folder, notebook, whiteboard, PDF and Markdown workflow;
it does not yet provide every Goodnotes feature. There are no account, marketplace or
collaboration features. Undo history stays with each open document. Library search matches
filenames/titles; workspace search matches text boxes and embedded PDF text. Scanned pages
and handwriting are not searchable yet. See [the parity audit](docs/PARITY.md) for remaining work.

120 Hz is requested on supported iPads, but physical Pencil latency and palm rejection
still need device measurement. PDF rendering/export happens on the main actor and very
large documents need profiling. PDF saves and editable sidecars are separate coordinated
writes, not a single transaction; a mismatched sidecar is ignored on reopen. PDFs containing
images or filled shapes use a generated visual page with preserved native annotations.
Encrypted originals remain unchanged; editing uses an explicitly unlocked copy.
Advanced forms (including radio groups, signatures and scripted calculations), destinations
in unusual rotated PDFs with generated appearance pages and provider-specific conflict
recovery need further work. Simulator UI tests exercise folder selection, notebook creation,
finger drawing, erasing, undo, continued-page creation and reopening.
Automated tests also cover existing-file protection,
external-change detection, editable PDF round trips and canvas rendering.

## Contributing

Open an issue describing a reproducible problem or proposed feature. Keep changes small,
run `swift test`, and build both platform destinations. Preserve PDF-point coordinates,
package compatibility, native APIs and clean-room provenance. Explain non-obvious
engineering decisions in comments; avoid describing self-evident syntax. Contributions
must use original code and assets, without proprietary Goodnotes source or artwork.

## License

MIT. Goodnotes is a trademark of its respective owner. NoteCraft is independent and
is not affiliated with or endorsed by Goodnotes.

## Shapes, stickers, text and images

- **Shapes** tool: pick a shape (line, arrow, right angle, rectangle, circle, triangle, …) and tap the
  page or drag to size it. Freehand mode snaps clear lines, rectangles, circles, triangles and right
  angles, turns smooth curves into clean splines and leaves anything else as ink.
- Shapes, stickers, images and text boxes share one editor: drag to move, corners scale, edge handles
  stretch, the top handle rotates (snapping to 15°). The bar below the selection recolors, deletes and
  opens the full menu (line width, fill, order, duplicate, save as element).
- **Elements** tool: vector stickers, emoji and saved elements; tap the page to place one.
- **Text** tool: tap to type in a small box right on the page; the slider icon opens font options.
- Paper background: pattern and paper color, for one page or all non-PDF pages.
