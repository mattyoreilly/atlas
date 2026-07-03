# Atlas 0.1.0

Initial release.

* `atlas()` builds up to `n_models` candidate models with an LLM agent:
  distribution-driven planning, plan approval, held-out comparison,
  feature refinement of the winner, and a written report. Stopping is
  controlled by `patience` and `min_improve`.
* Domain knowledge as enforced constraints: `constraint()`, `con_uses()`,
  `con_monotone()`, natural-language extraction via `extract_constraints()`,
  automatic repair rounds, and a compliance table in the results.
* Feature safety: `exclude` removes columns before the agent sees the data;
  `atlas_leakage_screen()` flags predictors that alone explain almost all of
  the outcome.
* Persistent sessions: `AtlasSession` checkpoints every code chunk and
  conversation turn to a run directory; `atlas_resume()` reconstructs a
  session exactly by replaying the code log. Builds can be interrupted and
  steered mid-run (`interject`).
* Optional extras: a point-and-click front-end (`atlas_app()`, requires
  'shiny') and a validation workup for the winning model (requires
  'modelblueprint').
