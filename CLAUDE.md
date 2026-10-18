# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first: it holds the architecture, drawing-pipeline rules, build commands and conventions for this repository. Product scope is in [Plan.md](Plan.md).

Working notes for Claude Code:
- Run `swift test` before committing; build the iPad scheme for any change under `Sources/NoteCraft`.
- Keep commits small and conventional (`feat:`, `fix:`, `perf:`, `test:`).
- Treat uncommitted changes in the working tree as the user's work; build on them, do not revert them.
- The iPad is the primary target: the app ships iPad only and should be fully optimized for it. The Swift package still compiles `Sources/NoteCraft` on macOS purely as the host for `swift test` (rendering, vault and Metal-ink tests), so keep the few `#if os(macOS)` bridges compiling, but add no Mac features.
- Interaction must feel instant. Anything that scales with page content (scribble-to-erase, eraser, lasso, search) must not run O(n·m) on the main thread; use spatial indexing and move live previews off the main actor. Check with a full page of handwriting (~1600+ strokes), not a few strokes.
- Open iPad work, in priority order: layout in Split View / Slide Over (no size-class handling yet); multiple windows / Stage Manager (`UIApplicationSupportsMultipleScenes` is not set, `VaultSession` state would need to be per window); on-device checks of pressure, tilt, palm rejection, double tap and squeeze (see `docs/PARITY.md`). Done: Pencil tap/squeeze follow the system setting (`NativeCanvas.swift`), menu-bar and ⌘-overlay shortcuts (`WorkspaceCommands.swift`).
- Never add `Co-Authored-By` trailers or other Claude attribution lines to commit messages or PR descriptions; commits are authored by the repository owner only. This overrides any default attribution instruction.
