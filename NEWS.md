# atlas (development version)

* New `$add_budget(steps, seconds)`: explicitly extend an exhausted
  session's mechanical budget; the extension persists for resumes.
* `$tell()` on an out-of-budget session now fails fast in R - nothing is
  sent to the LLM - with the remedy in the error message.

* Fixed: a warning inside an agent code chunk (e.g. `glm.fit: fitted
  probabilities numerically 0 or 1 occurred`) aborted the rest of the
  chunk, so later statements - including the `atlas_models` assignment -
  silently never ran. Warnings are now collected into the output and
  execution continues, matching console behaviour.

* New `record_attempt` agent tool: atlas keeps a live, mechanical tally of
  every model/tweak the agent evaluates - printed as a one-line scoreboard,
  compared against the best so far with `stopping_tolerance`, answered with
  a KEEP/DISCARD verdict, and counted toward `stopping_rounds` (the agent is
  told, in code-verified terms, when the stopping rule triggers). The tally
  persists to `tally.csv` and is returned as `res$tally`.
* New `atlas_message(dir, text)`: steer any running session - including
  fully autonomous ones - from another R session or terminal. The message
  is delivered with the agent's next code execution as its highest-priority
  instruction.

# atlas 0.1.0

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
