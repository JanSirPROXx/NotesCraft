# CLAUDE.md

Read [AGENTS.md](AGENTS.md) first: it holds the architecture, drawing-pipeline rules, build commands and conventions for this repository. Product scope is in [Plan.md](Plan.md).

Working notes for Claude Code:
- Run `swift test` before committing; build the iPad scheme for any change under `Sources/NoteCraft`.
- Keep commits small and conventional (`feat:`, `fix:`, `perf:`, `test:`).
- Treat uncommitted changes in the working tree as the user's work; build on them, do not revert them.
