# Changelog

## Atlas 0.1.0

Initial release.

- [`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md)
  builds up to `n_models` candidate models with an LLM agent:
  distribution-driven planning, plan approval, held-out comparison,
  feature refinement of the winner, and a written report. Stopping is
  controlled by `patience` and `min_improve`.
- Domain knowledge as enforced constraints:
  [`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md),
  [`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md),
  [`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md),
  natural-language extraction via
  [`extract_constraints()`](https://mattyoreilly.github.io/Atlas/reference/extract_constraints.md),
  automatic repair rounds, and a compliance table in the results.
- Feature safety: `exclude` removes columns before the agent sees the
  data;
  [`atlas_leakage_screen()`](https://mattyoreilly.github.io/Atlas/reference/atlas_leakage_screen.md)
  flags predictors that alone explain almost all of the outcome.
- Persistent sessions: `AtlasSession` checkpoints every code chunk and
  conversation turn to a run directory;
  [`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md)
  reconstructs a session exactly by replaying the code log. Builds can
  be interrupted and steered mid-run (`interject`).
- Optional extras: a point-and-click front-end
  ([`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md),
  requires ‘shiny’) and a validation workup for the winning model
  (requires ‘modelblueprint’).
