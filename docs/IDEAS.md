# Ideas

Parked ideas that are not scheduled. They are not commitments, and some of them change the guardrails in
[`AGENTS.md`](../AGENTS.md) (no third-party dependencies, no AI features), so each needs an explicit decision first.

## Community plugin system (Obsidian style)

Let the community write and share its own plugins that extend the app.

Open questions:
- What can a plugin do? Candidates: new pen/brush styles, page templates and paper patterns, stickers and element
  packs, import/export formats, shape recognizers, toolbar actions, the calculator pen (see CALCULATOR.md).
- Runtime. iPadOS forbids downloading and executing native code, so plugins would need to be declarative
  (JSON/asset bundles) or run in a sandbox such as JavaScriptCore with a small, versioned host API.
- Distribution: a plugin folder inside the vault (works with iCloud/OneDrive, no backend) versus a browsable
  community index. A backend conflicts with the "no backend" guardrail, so a static, GitHub-hosted index is the
  lean option.
- Permissions and review: plugins must not read other notebooks or the network without the user's consent.
- Stable API surface first: stroke, page and notebook models, tool hooks, and the file format in `docs/FORMAT.md`.

## Calculator pen (handwritten maths that solves itself)

Moved out of the parked ideas: the concept, decisions and phased plan are in [`CALCULATOR.md`](CALCULATOR.md).
