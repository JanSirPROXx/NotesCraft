# NoteCraft – Agent Guide

Clean-room, native Swift notebook app for iPad and Apple Pencil (the package also builds on macOS, only as the host for `swift test`), modelled on the classic
GoodNotes workflow. Product scope and philosophy live in [`Plan.md`](Plan.md); user-facing
behaviour in [`README.md`](README.md); file format in [`docs/FORMAT.md`](docs/FORMAT.md);
remaining feature gaps in [`docs/PARITY.md`](docs/PARITY.md).

## Guardrails (from Plan.md)

- Lean: Apple frameworks only, no third-party dependencies, no backend, accounts or cloud/AI services. The one bundled model is the on-device symbol recognizer of the calculator pen ([`docs/CALCULATOR.md`](docs/CALCULATOR.md)); nothing it reads leaves the device.
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

## Restoring what was open

`VaultController` remembers what was open (`OpenState` in UserDefaults key `openDocuments`: the storage, the library's folder, the open documents in tab order, the one in front, whether the library was showing) and `restoreLastStorage()` brings it back before the "Opening your library…" screen goes away, so after the iPad was off or the app was closed it opens on the notebook and page it was left on (the page comes from the per-document reading positions). The state is written when documents open, tabs change, the library is entered, files are renamed, moved or trashed and when the scene leaves the foreground (`persistOpenState()`); it is not written while it is being restored. A document that is gone or unreadable is skipped without a dialog. Scroll offset and zoom inside a page are not restored.

## Marketplace

A free catalog of packs (`theme`, `sticker`, `template`, `planner`); the guide for people who make packs is docs/MARKETPLACE.md. The catalog is the folder `catalog/` (`index.json`, `packs/*.ncpack`, `previews/*.png`), served from GitHub raw by default (`MarketplaceStore.defaultAddress`, changeable in Settings ▸ Marketplace, https only) and bundled into the app as a folder resource so the first start and offline use work. Layers: Core has the zip reader/writer with limits (`ZipArchive`), the index and its checks (`Catalog.swift`), pack opening, building and per-kind payload validation and `NotebookPackage.insertPages(of:)` / `asNewNotebook(title:)` (`Pack.swift`); the app has `MarketplaceStore` (sources, cached index, install/uninstall per kind, saved set, previews decoded at a bounded size) in Marketplace.swift and the screens in MarketplaceView.swift (Library switches to it with `marketplaceVisible`; installed templates are listed in `TemplatePicker`). Rules: the index's size and SHA-256 are the only trust anchor (`Pack.open(_:expecting:)` checks them and that the manifest matches), a pack holds no code, paths are relative and inside `content/`, sticker clips get fresh ids on install, and everything a pack added is removed by `uninstall` while what was made with it stays. The starter packs are generated by `Tests/NoteCraftTests/StarterCatalog.swift` (`NOTECRAFT_BUILD_CATALOG=1 swift test --filter buildTheStarterCatalog`; deterministic) and `RepositoryCatalogTests` opens every committed pack the way the app does, so a pull request that adds a pack is tested by `swift test` and `python3 scripts/catalog.py check`. UI tests use `--ui-test-offline-catalog` (no network) and `--ui-test-reset-marketplace`.

## Toolbar and tool state

`Workspace.swift` owns tool state. `toolBar` (primary tools) and `contextualToolBar` (quick bar: undo/redo, pen style, colors, thickness presets) are SwiftUI. Every tappable control needs a minimum 44×44 pt hit area with an explicit `.contentShape`, because `.buttonStyle(.plain)` only hits drawn pixels.

## Calculator pen

Write a calculation with the calculator pen, finish it with `=`, and the answer is written next to it; the concept, decisions and phases are in docs/CALCULATOR.md. Pieces: Core `Calculator/Expression.swift` (exact `Decimal` arithmetic and the parser, English notation: `.` is the decimal point, `,` only groups thousands, anything unreadable is an error and never a guess), `Gathering.swift` (`CalculatorTrigger.gathering(for:on:)`: is the stroke just written the second bar of an `=`, and which strokes make up the calculation), `Reading.swift` (`ExpressionRecognizing`, `Calculator.outcome`, the answer `TextBox`, `pruned`); the app has `CalculatorCoordinator` (patience, glow and dots, reading off the main actor, inserting the answer), `CalculatorEffects.swift` (the Core Animation layers in `DrawingView`) and `CalculationEditor` (hand correction).

Rules that hold the feature together:
- The pen is a *tool of the bar* only. The canvas gets `.pen` plus `CanvasConfiguration.calculator`, and the stroke is stored as a `pen` stroke with `calculator: true` (docs/FORMAT.md), so older builds still read the page. Only such strokes are ever read, never by colour. Set the marker where the stroke is made (`DrawingView.finish`) so the stroke equals `pendingStroke` and takes the fast path into the page cache.
- An answer is a `TextBox` with a `CalculationLink` naming its strokes. It is inserted without its own undo step (one undo takes the `=` and the answer), nothing is recalculated on open, and `Workspace.edit` drops an answer whose strokes are gone (`Calculator.pruned`).
- Nothing runs while writing. After the second bar of an `=` the coordinator waits `patience`; any pen-down cancels it. Reading is async and off the main actor; the dots stay at least `shortestReading` so a fast reading does not flash. A reading that is missing or below `minimumConfidence` becomes `?`, never a number.
- Glow and dots are layers in `CalculatorEffectsView`, driven by `CanvasConfiguration.calculatorActivities`. They never repaint tiles; state changes only when an animation starts or ends. Reduce Motion gets a plain fade.
- The first pick of the pen shows `CalculatorIntroView` (a looping drawn demo and two sentences; `Preferences.calculatorIntroSeen`), and the pen's settings reopen it ("How it works"). The demo is drawn in a `Canvas`, not a video, so it needs no asset and shows the pen's colour; Reduce Motion gets the finished picture. Do not put an `accessibilityIdentifier` on a container: it replaces those of the views inside.
- The recognizer is a template matcher, not a trained model (`SymbolClassifier`, `LineReader`, `TemplateRecognizer` in Core `Calculator/`): the stock shapes of `Glyphs.swift` plus the reader's own symbol samples (`CalculatorCorpusStore`, Settings ▸ Calculator pen ▸ Teach your handwriting, shown full screen because a sheet's swipe-to-close cancels strokes written on it). The rule it keeps: a wrong reading is never presented as certain; an unclear symbol keeps its alternatives and the grammar decides, a rival cut of the strokes makes the reading unsure, and `Calculator.minimumConfidence` turns anything unsure into `?`. There is no handwritten "/" (a slanted "1" is the same stroke). Before changing a threshold or a glyph run the benchmark: `NOTECRAFT_RECOGNITION_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --filter SymbolRecognition` (the plain `swift test` runs a small sample).
- A calculation that cannot be read ends as `?` and is corrected by a finger tap on it (Pencil-only on) or Selection ▸ Edit calculation; the correction is kept as a sample. UI tests use `--ui-test-calculator-reading=<expression>` to give a reading and `--ui-test-no-recognizer` for none.

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
