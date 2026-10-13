# Ideas

Parked ideas that are not scheduled. They are not commitments, and some of them change the guardrails in
[`AGENTS.md`](../AGENTS.md) (no third-party dependencies, no AI features), so each needs an explicit decision first.

## Community plugin system (Obsidian style)

Let the community write and share its own plugins that extend the app.

Open questions:
- What can a plugin do? Candidates: new pen/brush styles, page templates and paper patterns, stickers and element
  packs, import/export formats, shape recognizers, toolbar actions, the calculator pen below.
- Runtime. iPadOS forbids downloading and executing native code, so plugins would need to be declarative
  (JSON/asset bundles) or run in a sandbox such as JavaScriptCore with a small, versioned host API.
- Distribution: a plugin folder inside the vault (works with iCloud/OneDrive, no backend) versus a browsable
  community index. A backend conflicts with the "no backend" guardrail, so a static, GitHub-hosted index is the
  lean option.
- Permissions and review: plugins must not read other notebooks or the network without the user's consent.
- Stable API surface first: stroke, page and notebook models, tool hooks, and the file format in `docs/FORMAT.md`.

## Calculator pen (handwritten maths that solves itself)

A dedicated "calculator" pen. Write an expression or equation by hand, trigger it, and the result is written
next to it in handwriting style.

Examples:
- `2+2=` adds `4`.
- `10 = 2x + 2` followed by `x =` adds the solution for `x`.
- It should cover real maths: sums and products (`Σ`, `Π`), integrals, limits, fractions, powers, roots,
  matrices, units, and systems of equations.

Open questions:
- Recognition: turning the drawn strokes into symbols. The strokes (with timing) are already stored, which helps.
  Options: a small on-device Core ML handwritten-math model (strokes to LaTeX), Apple Vision text recognition
  (weak for maths), or a larger model. Everything should stay on device.
- Solving: a small expression parser and evaluator for arithmetic; symbolic solving (equations, sums, integrals)
  is much more work and might need an embedded algebra engine.
- Trigger: auto-evaluate when the pen pauses after `=`, or an explicit action (tap, double-tap Pencil, lasso
  then "Solve").
- Output: write the result as ink in the user's handwriting, or as a typeset text object that stays editable and
  recalculates when the input changes.
- Guardrail check: "no AI features" and "no third-party dependencies" would need to be relaxed for a
  recognition model; decide whether a bundled model counts.
