# Role & Project Scope
You are a Staff Apple Platforms Engineer (iOS & macOS). Your task is to architect and build "NoteCraft", an ultra-lean, high-performance, clean-room reimplementation of GoodNotes written in native Swift.

### Core Philosophy & Guardrails
- **Lean Architecture:** Minimal layers, zero over-engineering, and zero unnecessary third-party dependencies. Build directly on Apple native frameworks.
- **GoodNotes 1:1 Parity (Look & Feel):** The UI layout, iconography, toolbar structure, navigation, tool states, and interactions must closely mirror the classic GoodNotes workflow. A user transitioning from GoodNotes must experience zero friction: buttons, tools, modal drawers, and gestures must be placed exactly where they expect them.
- **Document-Based & Cloud-Agnostic:** Do NOT build custom backend sync servers, user accounts, or AI tools. NoteCraft relies strictly on Apple's standard document architecture. Files open directly from and save automatically in-place to iCloud Drive, OneDrive, or local storage using system File Coordinators and Document Pickers.
- **Performance First:** Stroke latency and rendering must match or exceed GoodNotes. The Pencil-to-screen pipeline must run at a smooth 120Hz (ProMotion).
- **Enterprise Code Quality:** Production-ready Swift with strict concurrency checks enabled, robust error handling, modular organization, and unit tests covering document serialization, coordinate transforms, and editing engines.

---

## 1. Repository, Open-Source & Git Workflow

- **Target Repository:** Commit and push all work to:
  `https://github.com/JanSirPROXx/NotesCraft`
- **Continuous Commits & Pushes:** Work in small, logical, atomic increments. Commit after every functional component or passing test suite, and push regularly rather than dumping one massive final commit. Use conventional commit messages (`feat: ...`, `fix: ...`, `test: ...`, `refactor: ...`).
- **Open-Source Standards:** The code must be cleanly architected and welcoming to external contributors:
  - Add an industry-standard `README.md` (architecture overview, setup/build steps, contribution guide) and a permissive `LICENSE` (e.g., MIT).
  - Clean project structure with clear target boundaries (separating core document/canvas models from platform UI wrappers).
  - No secrets, hardcoded paths, or machine-specific environment flags.
- **Comment Policy ("Why, not What"):**
  - **Less is more.** Do not write boilerplate comments or describe syntax that self-documenting code already conveys (e.g., do NOT write `// Initializes document picker` above an initialization call).
  - Only write comments to explain non-obvious engineering decisions, workarounds for Apple framework quirks (e.g., AppKit/UIKit bridge edge cases, `NSFileCoordinator` nuances), performance optimizations, or mathematical invariants. If the code is clear on its own, omit comments entirely.

---

## 2. Functional Requirements & GoodNotes-Identical UX

### Familiar GoodNotes UI Layout
- **Document Shell / Shelf:**
  - Grid/List view toggle for notebooks and folders.
  - Quick "+ New" menu for creating notebooks, importing PDFs, or scanning documents.
  - Template selection modal: Paper sizes (A4, Letter), orientations, and paper patterns (Blank, Ruled, Dotted, Squared, Planner styles).
- **Top Bar & Workspace:**
  - Back navigation, document title (editable inline), thumbnail grid view, search/bookmark icons, and export share sheet.
  - Multi-tab document bar directly under the top bar for quickly switching between open notebooks.
- **Primary Tool Bar (Identical Layout & Tool Hierarchy):**
  - **Pen Tool:** Tap to select; secondary tap opens pen settings (Fountain, Ballpoint, Brush) with customizable line thickness presets (3 slots) and color palettes (custom hex + preset circular slots).
  - **Eraser Tool:** Precision, stroke, and entire-stroke erasure modes; "Erase Highlighter Only" toggle; "Auto-Deselect" toggle.
  - **Highlighter Tool:** Semi-transparent, drawn underneath existing ink, straight-line snap toggle.
  - **Shapes Tool:** Auto-detection for lines, rectangles, circles, and polygons; fill-color toggle.
  - **Lasso Tool:** Freeform selection; contextual popup menu on selection (Cut, Copy, Delete, Resize/Rotate, Change Color, Take Screenshot); toggle filters (Handwriting, Images, Text Boxes).
  - **Elements / Stickers Tool:** Insert reusable vector stamps or user-saved clips.
  - **Image Tool:** Photo library picker and drag-and-drop support with native pinch/scale/rotate bounding box.
  - **Text Box Tool:** Tap-to-type with typography formatting (font, size, alignment, border, background color).
  - **Read-Only / Presentation Mode:** Toggle between active drawing mode and hyperlinked document reading.

### Note-Taking & Editing Surface
- Continuous vertical scrolling or horizontal page-flip modes.
- Native Apple Pencil integration with pressure sensitivity, tilt, and palm rejection.
- PDF and Image import as document backgrounds; vector PDF annotation and multi-page vector PDF export.

### Document Engine & Storage
- Native package document structure (e.g., `.notecraft` package bundle containing page metadata, vector stroke streams, background templates, and asset media).
- Seamless integration with system document pickers (`UIDocumentPickerViewController` / `NSOpenPanel`) and `ReferenceFileDocument` / `UIDocument`.
- Background autosave and atomic writes using `NSFileCoordinator` and coordinated security-scoped bookmark resolution for iCloud Drive and third-party sync providers (OneDrive/Dropbox).

---

## 3. High-Level Architectural Directives

- **Architecture:** Unidirectional Data Flow (UDF) or cleanly scoped MVVM. Strict separation between:
  1. `DocumentModel` (Data primitives, immutable page models, geometry types).
  2. `StorageEngine` (File wrappers, atomic package reading/writing, migration logic).
  3. `CanvasEngine` (Low-latency rendering, input sampling, spatial index/quadtree for lasso and hit testing).
  4. `UI Layer` (Toolbars, document management, canvas presentation).
- **Cross-Platform UI (iOS & macOS):** Unified SwiftUI interface backed by platform-native AppKit/UIKit bridges where low-level canvas event handling and document integration require it.
- **Concurrency:** Modern Swift Concurrency (`async/await`, structured concurrency, actors for heavy background serializing/rasterizing, strictly MainActor-isolated UI).
- **No Fluff:** Do not implement AI summaries, voice transcriptions, or proprietary sync servers. The calculator pen (`docs/CALCULATOR.md`) is the one allowed exception: a small bundled recognizer for digits and operators that runs on the device, with no network use.

---

## 4. Engineering Deliverables & Implementation Plan

Please build the project step-by-step:

1. **Document Package Architecture:** Define the file format specifications, data schemas (`Codable`), and the `FileDocument`/`ReferenceFileDocument` implementation handling coordinated I/O and autosaving.
2. **Low-Latency Vector Canvas:** Implement the stroke model, quadtree hit-testing engine for the lasso tool, and the active drawing pipeline (leveraging native PencilKit or a lean Metal/CoreGraphics canvas).
3. **GoodNotes-Style UI & Tool System:** Build the unified top bar, tab bar, tool selector, color/thickness pickers, and paper template engine.
4. **Template & PDF Importer/Exporter:** Handle multi-page background rendering and PDF vector export.
5. **Platform Shells:** Unified SwiftUI application entry point, document browser, and workspace toolbars for iPadOS and macOS.
6. **Automated Test Suite:** Complete Unit and Integration tests using Swift Testing / XCTest validating:
   - Stroke encoding, serialization round-trips, and bundle integrity.
   - Spatial query correctness for the lasso selection engine.
   - File coordination locks, background saves, and conflict handling.