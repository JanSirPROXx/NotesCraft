# NoteCraft – Agent Guide

Clean-room, native Swift notebook app for iPad and Apple Pencil (the package also builds on macOS, only as the host for `swift test`), modelled on the classic
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

1. `DrawingView` (UIView/NSView) receives touches, appends `Sample`s and, on iPad, coalesced and predicted touches. Pen samples pass through `InkSmoother` (a time-based 1 € filter, parameters in screen points) as they arrive, so the live ink and the stored stroke are the same line and the stabilization setting only changes its strength; predicted samples go through a copy of the filter. Pencil force and tilt arrive late as estimates: `PendingEstimates` tracks the samples still waiting, `touchesEstimatedPropertiesUpdated` patches them and `FountainTrack` re-derives the widths from there. `LiveInkPlan` decides which segments are baked for good (never past a sample still waiting) and which are redrawn each frame, for both the GPU and the CoreGraphics path.
2. Existing page content is cached. A page shown by the document view (iPad) is drawn as tiles: `PageTileView` (Sources/NoteCraft/PageTiles.swift, grid maths in `TileGrid`) keeps only the tiles near the visible part of the page, at exactly the density it is seen at (screen scale times zoom, from the `canvasDensity` environment value), so a page is sharp at 6x and costs memory in proportion to the screen, not the zoom. `DrawingView` then draws nothing itself: everything that is not the page (selection, moving objects, eraser reach, the stroke just lifted) is painted by `paintDynamic` into the transparent `inkOverlay`, and `setNeedsDisplay` is forwarded there. A committed stroke goes into the tiles it touches (`append`), the eraser patches them (`patch`), any other model change is turned into the changed area by `PageDiff` and only those tiles are redrawn (`invalidate(inPageRect:)`, deferred to layout so it sees the final state). Whiteboards and the Library preview still use one `CGLayer` (`cachedPage`) at device resolution; invalidate it only when the page, assets, viewport or resolution change.
3. The active pen stroke is drawn on the GPU (iOS): `MetalInkView` (a `CAMetalLayer` above the page) fills "cones" produced by `InkTessellator`, which mirrors `PageRenderer.smoothInkSegments`. Finished segments accumulate in a persistent texture, only the unstable tail plus predicted samples are drawn each frame, and rendering runs once per display frame (mid-frame from the `UIUpdateLink` action on iOS 18+, which also asks for low-latency Pencil event dispatch while inking). `MetalInkTests` keeps the GPU output within a small error of the CoreGraphics stroke so nothing changes at pen-up. The "Fast GPU ink" toggle switches back to the previous CoreGraphics path: the stroke is rendered incrementally into `inkOverlay`, a transparent subview of `DrawingView`, so a new sample never re-blits the page cache: finished segments are baked into `input.liveLayer`, only the tail plus predicted samples is redrawn each frame. macOS draws the live stroke in the view itself.
   On a page in tiles the Metal view covers only the part of the page that is on screen, at the page's tile density, and is placed when a stroke starts (`placeGPUInkWindow`): the drawable is a screen of pixels at any zoom, and the live ink is as sharp as the committed ink.
4. On touch end the stroke is stored as `pendingStroke`, handed to `onStroke`, and drawn straight into the page cache or tiles once the model update arrives, so no full re-render is needed.

Rules that keep latency low:
- Invalidate with dirty rects (`setNeedsDisplay(_:)`), never the whole view, while drawing.
- Do not rebuild `cachedPage` or the tiles, or run SwiftUI state changes per touch sample.
- Config changes that do not affect pixels (color, width, pen style outside an active stroke) must not repaint.

## Notebook scrolling and zoom

The notebook is one `UIScrollView` (`NotebookDocumentController` in `NotebookDocumentView.swift`) that scrolls and zooms all pages together. `NotebookLayout` (Core, pure) works out where the pages sit at zoom 1, which are near the view and which one is current, and keeps the reader's place across a resize through anchors; only the pages near the view are built, one per pass, with a blank sheet in place of the others. The pages report their place and zoom to SwiftUI only when the paper has come to rest. Whatever floats over the document while it moves (`PageIndicator`, `ZoomIndicator`, `PageScrubber`) is UIKit, because a SwiftUI state change per frame of a scroll or pinch costs a pass over every page on screen; the maths of the scrubber handle is `Scrubber` in Core. Pencil never moves the paper and nothing floating over it takes a Pencil touch.

A row (horizontal pages) is a pager with a shared zoom. `NotebookLayout` gives every page a cell as wide as the view at fit, and, once the page is wider than the view, the page plus a gap that closes with the zoom (`rowGap(atZoom:)`, a thin line when zoomed); the layout is made again for the zoom when a pinch ends. A page is turned by `release`: a drag that starts inside a zoomed page may only pan across that page (`dragRange` becomes the scroll view's inset, so the edge bounces), a drag that starts at the edge of the page may go on into the next one and turns it when it is fast (`flickSpeed`) or far enough, and a turn only moves the view sideways, so the zoom and the height stay. Fit is the same rule with a page that fills its cell.

## Settings

`SettingsView` (Settings.swift) is the one place for preferences; it is a sheet reached from the gear in the library and from Settings in the ⋯ menu of a notebook, and the ⋯ menu otherwise only holds actions on the page and document. Preferences are `@AppStorage` values whose keys are the constants in `Preferences`; the workspace reads the same keys, so a switch is read where it is used and written in one place only. A new preference gets a key there, a control in the right section of `SettingsView`, and a UI test that flips it. The toolbar's tools and their order are `ToolbarLayout` (Core, tested), stored as two strings.

## Appearance (themes)

Nothing in the UI chrome has a color, font or icon of its own: ask `ThemeStore.shared` through `Color.theme(.token)`, `UIColor.theme(.token)`, `.font(.theme(size, weight))` / `.font(.theme(.caption))`, `Symbol("sf.name")` (an icon the theme may replace; `Icon.name("sf.name")` where only a symbol name is taken, as in menu items) and `.corner(radius)`. The store is `@Observable`, so a view that reads it in its body is redrawn when the theme or the mode changes; UIKit views refresh in `update`. A new color is a case of `ThemeColorToken` with a value in every built-in theme (`ThemeTests` checks completeness and contrast) and a row in docs/THEMES.md. Page content (paper, ink, covers, the screenshot tour) is not chrome and keeps its own colors. Never force a color scheme on a view: the root draws in the theme's scheme (`ThemedRoot`), and sheets use `themedSheet()`. The format, the package checks and the built-in themes are in `Theme*.swift` in Core and the store in Appearance.swift; the authoring guide is docs/THEMES.md and `docs/themes/sunset.notecrafttheme` is tested.

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
