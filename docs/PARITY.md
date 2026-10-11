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
- Notebook papers support native finger pinch zoom up to 6× and panning while zoomed.
- Horizontal paging is the persistent default; the editor menu can switch to vertical.
  Holding an outward pull beyond the last page appends matching paper in either direction.
- Image tool immediately offers Files/Photos, selects inserted images, and provides direct
  move, corner resize, pinch resize and rotation gestures with undo.
- The bottom status/zoom bar is removed. A page indicator fades after navigation or strong scrolling.
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

Accounts, proprietary cloud collaboration, marketplace and AI features are outside the
local clean-room scope described in Plan.md.

## Verification

Swift tests cover group geometry, rotated text/PDF round trips, reusable element
persistence and collision-safe insertion, page cloning, PDF search, vault conflicts,
drawing input and export. Native UI coverage exercises folder selection, default
finger navigation, opt-in finger ink, erase/undo, reopen, pull-to-add-page, thumbnail
duplication, both paging directions, transient page indicators, notebook pinch zoom,
immediate image source selection, library rename/duplicate/trash/restore, page-number
navigation and whiteboard drawing/zoom. Simulator input does
not establish physical Pencil or palm behavior.
