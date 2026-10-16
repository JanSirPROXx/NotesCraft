# NoteCraft – Agent Guide

Clean-room, native Swift notebook app for iPadOS and macOS, modelled on the classic
GoodNotes workflow. Product scope and philosophy live in [`Plan.md`](Plan.md); user-facing
behaviour in [`README.md`](README.md); file format in [`docs/FORMAT.md`](docs/FORMAT.md);
remaining feature gaps in [`docs/PARITY.md`](docs/PARITY.md).

## Guardrails (from Plan.md)

- Lean: Apple frameworks only, no third-party dependencies, no backend, accounts or AI features.
- GoodNotes parity for layout, tool hierarchy and gestures. Tap a selected tool again for its settings.
- Document based: files open and autosave in place (iCloud Drive, OneDrive, local) through file coordination.
- Performance first: Pencil-to-screen latency must feel like paper; target 120 Hz on ProMotion.
- Swift 6, strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`). UI is `@MainActor`; heavy work goes to actors.
- Original code and assets only. Never copy Goodnotes source or artwork.

## Layout

| Path | Role |
| --- | --- |
| `Sources/NoteCraftCore` | Platform-neutral models (`Notebook`, `Page`, `Stroke`, `Sample`), quadtree, lasso, erasure, shape recognition, package codec, vault file actors. |
| `Sources/NoteCraft` | SwiftUI app: `Library` (folder browser), `Workspace` (editor, toolbars), `NativeCanvas` (UIKit/AppKit drawing view), `Renderer` (CoreGraphics page/stroke rendering and PDF export), `PDFEditor`, `VaultSession`. |
| `Tests/NoteCraftCoreTests`, `Tests/NoteCraftTests` | Swift Testing unit/integration tests. |
| `Tests/NoteCraftUITests` | XCUITest flows on the iPad simulator. |
| `project.yml` | XcodeGen spec; `NoteCraft.xcodeproj` is checked in and regenerated with `xcodegen generate`. |

Coordinates are PDF points everywhere in the model. Views convert through `ViewTransform` or the page scale.

## Drawing pipeline (read before touching `NativeCanvas.swift` / `Renderer.swift`)

1. `DrawingView` (UIView/NSView) receives touches, appends `Sample`s and, on iPad, coalesced and predicted touches.
2. Existing page content is cached in a `CGLayer` (`cachedPage`) at device resolution; invalidate it only when the page, assets, viewport or resolution change.
3. The active pen stroke is drawn on the GPU (iOS): `MetalInkView` (a `CAMetalLayer` above the page) fills "cones" produced by `InkTessellator`, which mirrors `PageRenderer.smoothInkSegments`. Finished segments accumulate in a persistent texture, only the unstable tail plus predicted samples are drawn each frame, and rendering runs once per display frame (mid-frame from the `UIUpdateLink` action on iOS 18+, which also asks for low-latency Pencil event dispatch while inking). `MetalInkTests` keeps the GPU output within a small error of the CoreGraphics stroke so nothing changes at pen-up. The "Fast GPU ink" toggle switches back to the previous CoreGraphics path: the stroke is rendered incrementally into `inkOverlay`, a transparent subview of `DrawingView`, so a new sample never re-blits the page cache: finished segments are baked into `input.liveLayer`, only the tail plus predicted samples is redrawn each frame. macOS draws the live stroke in the view itself.
4. On touch end the stroke is stored as `pendingStroke`, handed to `onStroke`, and drawn straight into the page cache once the model update arrives, so no full re-render is needed.

Rules that keep latency low:
- Invalidate with dirty rects (`setNeedsDisplay(_:)`), never the whole view, while drawing.
- Do not rebuild `cachedPage` or run SwiftUI state changes per touch sample.
- Config changes that do not affect pixels (color, width, pen style outside an active stroke) must not repaint.

## Toolbar and tool state

`Workspace.swift` owns tool state. `toolBar` (primary tools) and `contextualToolBar` (quick bar: undo/redo, pen style, colors, thickness presets) are SwiftUI. Every tappable control needs a minimum 44×44 pt hit area with an explicit `.contentShape`, because `.buttonStyle(.plain)` only hits drawn pixels.

## Build and test

```sh
swift build                      # macOS package build
swift test                       # core, rendering and vault tests (macOS)
xcodebuild -project NoteCraft.xcodeproj -scheme NoteCraft-iPad \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
xcodebuild ... test              # includes the iPad UI tests
```

## Conventions

- Commits: conventional (`feat:`, `fix:`, `perf:`, `test:`, `refactor:`), small and atomic; run the tests first.
- Comments explain *why* (Apple framework quirks, performance, invariants), never *what*.
- Prefer extending existing types over adding layers. Keep files focused; add tests for model, transform and rendering changes.
- Do not commit machine-specific paths, signing identities or secrets.
