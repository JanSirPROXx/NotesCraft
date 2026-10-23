# Clean-room parity audit

This is an independently implemented local notebook app. Visual references inform the
layout; no proprietary Goodnotes code, artwork or services are used. Full 1:1 parity
has not been established.

## Implemented

- Direct lasso corner resize, rotation handle and a nearby selection menu. Mixed groups
  transform around a shared center; each gesture creates one undo operation.
- Rotated text rendering, hit testing, storage and searchable PDF export.
- Named reusable elements containing handwriting, text and images; rename/delete,
  persistent storage and insertion across notebooks without asset collisions.
- Thumbnail actions to insert, duplicate, reorder, bookmark and delete pages.
- Horizontal page snapping and PDF/typed-text search with page navigation and highlights.
- Pencil-only drawing remains the default; fingers navigate.
- Library rename, move, duplicate, recoverable trash, restore, permanent deletion and
  Empty Trash; PDF sidecars and open sessions follow file operations.
- Visible file actions, folder breadcrumbs, persistent view/sort settings and trash undo.
- The notebook is one scroll view: whole-document finger pinch zoom (50 % to 600 %) and panning.
- Vertical scrolling is the persistent default, as in Goodnotes; the editor menu can switch to
  horizontal paging. Pulling beyond the last page appends matching paper in either direction.
- Image tool immediately offers Files/Photos, selects inserted images, and provides direct
  move, corner resize, pinch resize and rotation gestures with undo.
- Standalone images open in a read-only, zoomable preview. Explicit import creates an editable
  notebook; images inserted into existing notebooks retain move/resize/rotation controls.
  Previously saved image annotation packages can be recovered through notebook import.
- Multiple storage folders persist as security-scoped bookmarks in the sidebar. Startup
  opens the last storage automatically and migrates the previous single-folder bookmark.
  Switching storage flushes open edits before releasing the old folder.
- Each PDF/notebook remembers its page independently across reopen and app restart.
  Stored page IDs survive reordering; page indexes provide a fallback for fresh PDF imports.
  Positions follow file renames and moves without changing document content.
- The user-provided NotesCraft artwork is configured as the iPad and macOS app icon.
- The bottom status/zoom bar is removed. A page indicator fades after navigation or strong scrolling. While the notebook is zoomed, a pill at the bottom left shows the zoom (100% is fit to width) with a button that fits the width again (⌘0 does the same). The scroll bar is a handle on the edge that appears while the notebook scrolls and can be dragged to run through the pages, with the page in a bubble beside it.
- Password entry opens a separate unlocked PDF copy. Page-number navigation, bookmarks,
  PDF table of contents, single-page export and basic form filling are available.
- Export preserves outlines and remaps internal link destinations after page reordering;
  links/outline leaves targeting removed pages are disabled/omitted.

## Remaining before claiming parity

- Physical iPad verification of Pencil pressure/tilt, palm rejection, double tap,
  scrolling while the hand rests on screen, shape holds and latency at 120 Hz.
- Renaming/moving Markdown files does not rewrite wiki links in other vault notes.
- Handwriting recognition/search, OCR for scanned PDFs and searchable handwriting export.
- Advanced PDF forms: radio groups, signatures, shared-field behavior and scripted
  calculations. Destination geometry in rotated PDFs with generated appearance pages
  and large-document rendering/import/export profiling.
- Provider-specific conflict recovery and a recoverable PDF/sidecar save transaction.
- Broader editing parity such as audio recording/playback, image cropping, richer text
  formatting, study sets and more template/cover customization.
- Screenshot comparison on physical iPad sizes and both appearance settings, followed
  by spacing, toolbar, menu and animation refinements. Current editor is explicitly light.

## Compared with the Goodnotes Mac app (checked October 2026)

Its Tools menu lists Elements, Eraser, Highlighter, Image, Lasso, Laser, Pen, Pencil, Draw Shape,
Shape, Sticky Notes, Tape, Text, Writing, Ruler and Timer. The pen popover has fountain/ball/brush,
tip sharpness, pressure sensitivity, tip flatness and stroke stabilization (all present here), plus
Adjust Thickness by Speed, Reduce Latency, Draw and Hold (snap to other shapes, fill), Scribble to
Erase and Circle to Lasso.

Circle to Lasso (hold the pen on a loop) and the Pencil are built here; the Pencil is a pen style in
the pen's quick bar rather than a separate tool in a palette.

Not built yet, in the order they matter for writing:

- Tape: strips that hide the content under them, with Straight Tape and Remove All Tape.
- Laser pointer, Ruler, Timer and Sticky Notes.
- A switch for Adjust Thickness by Speed (the fountain pen always does it).
- Highlighter ink is a raw polyline: it does not go through the pen's smoothing yet.
- New Quick Record (audio), Study Set, QuickNote and Text Document from the File menu.
- A zoomed page is drawn again as tiles when a pinch ends, and stays soft only until the tiles on
  screen have arrived. The selection handles and the live highlighter are still drawn into a
  full-page overlay whose density is capped, so they are soft past about 3.5x zoom.
- The pencil grain is laid out in page coordinates at two texels per point and sampled without
  smoothing, so it shows as small squares at high zoom.

Handwriting recognition, spell check of handwriting and math assist depend on a recognition model
and stay out of scope together with the items below.

Accounts, proprietary cloud collaboration, marketplace and AI features are outside the
local clean-room scope described in Plan.md.

## Verification

Swift tests cover group geometry, rotated text/PDF round trips, reusable element
persistence and collision-safe insertion, page cloning, PDF search, vault conflicts,
drawing input and export. Native UI coverage exercises folder selection, default
finger navigation, opt-in finger ink, erase/undo, reopen, pull-to-add-page, thumbnail
duplication, both paging directions, transient page indicators, notebook pinch zoom,
immediate image source selection, library rename/duplicate/trash/restore, page-number
navigation, whiteboard drawing/zoom and last-storage/page restoration after app relaunch. Simulator input does
not establish physical Pencil or palm behavior.

- Notebooks and whiteboards offer blank, lined, dotted, large squares and 5 mm / 2.5 mm graph backgrounds; notebooks also offer weekly planner paper. Backgrounds can be changed on existing pages without changing ink, images or page dimensions, and applied across non-PDF pages. Whiteboard patterns continue across negative and distant canvas coordinates and PDF exports. New notebook pages inherit the current paper selection.

- The workspace uses compact tabs and one blue tool row, with contextual pen, shape and eraser controls floating over the canvas. Horizontal gestures settle on one adjacent page; the paper viewport has no fixed top/bottom gutters. New pages retain the previous page zoom and start at the top left by default; “Keep zoom on new pages” disables this. Handwriting renders through quadratic curves with round caps, while geometric strokes retain corners. Actual Pencil latency and feel still require testing on physical iPad hardware.

- Live handwriting caches finalized midpoint segments and redraws only the provisional/predicted tail. Starting a stroke retains the paper/PDF cache, and an ordinary pen commit appends to it. Predicted points never enter the finalized cache or saved stroke. Hold-to-shape uses one reschedulable task per stroke; stationary ink no longer triggers continuous redraws. `swift test --filter longStrokeLiveRenderingBenchmark` compares 120 frames of a 2,000-point brush stroke; measured macOS debug rendering was approximately 18–22 times faster in this workload. This measures CPU rendering work, not physical Pencil-to-screen latency.
