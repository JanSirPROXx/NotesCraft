# Clean-room parity audit

This is an independently implemented local notebook app. Visual references inform the
layout; no proprietary Goodnotes code, artwork or services are used. Full 1:1 parity
has not been established.

## Implemented in this iteration

- Direct lasso corner resize, rotation handle and a nearby selection menu. Mixed groups
  transform around a shared center; each gesture creates one undo operation.
- Rotated text rendering, hit testing, storage and searchable PDF export.
- Named reusable elements containing handwriting, text and images; rename/delete,
  persistent storage and insertion across notebooks without asset collisions.
- Thumbnail actions to insert, duplicate, reorder, bookmark and delete pages.
- Horizontal page snapping and PDF/typed-text search with page navigation and highlights.
- Pencil-only drawing remains the default; fingers navigate.

## Remaining before claiming parity

- Physical iPad verification of Pencil pressure/tilt, palm rejection, double tap,
  scrolling while the hand rests on screen, shape holds and latency at 120 Hz.
- Library rename, move, duplicate and recoverable trash, including PDF sidecars and
  open-document sessions. Folder/file browsing and creation already work.
- Handwriting recognition/search, OCR for scanned PDFs and searchable handwriting export.
- Password entry for encrypted PDFs; advanced PDF forms, outlines and destination
  preservation; large-document rendering/import/export profiling.
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
duplication, horizontal snapping and whiteboard drawing/zoom. Simulator input does
not establish physical Pencil or palm behavior.
