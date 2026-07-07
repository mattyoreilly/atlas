# Build models automatically with an LLM agent

One-call convenience wrapper around
[atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md):
hands your data to an agentic LLM that explores it, proposes a plan for
your approval, fits and evaluates `n_models` candidate models, and
returns the fitted models with a leaderboard and a report of how each
was built. Progress streams to the console; the agent pauses for your
input when it needs a decision. All state is checkpointed to a run
directory, so an interrupted run can be picked up with
[`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md).

## Usage

``` r
atlas(
  data,
  outcome,
  n_models = 3,
  goal = NULL,
  constraints = NULL,
  chat = NULL,
  dir = NULL,
  verbose = TRUE,
  max_fix_rounds = 2,
  stopping_rounds = 3,
  stopping_tolerance = 0.05,
  refine = TRUE,
  validate = TRUE,
  exclude = NULL,
  autonomous = FALSE,
  test_prop = 0,
  compact_at = 1e+05,
  max_steps = Inf,
  max_runtime = Inf
)
```

## Arguments

- data:

  A data.frame.

- outcome:

  Name of the outcome column (string).

- n_models:

  Maximum number of candidate models to build; the agent stops earlier
  when the stopping rules trigger (see `stopping_rounds` and
  `stopping_tolerance`).

- goal:

  Optional extra instructions (your own system-prompt additions), e.g.
  "prioritise interpretability" or "don't use tree-based models".

- constraints:

  Domain knowledge as hard requirements: a list of plain strings
  (enforced via instructions) and/or
  [`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md)
  objects with a `check` function (verified against every final model;
  violations are sent back to the agent to fix, up to `max_fix_rounds`
  times). Helpers:
  [`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md)
  (a variable must be used),
  [`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md)
  (predictions monotonic in a variable). Compliance is reported in the
  `constraints` element of the result.

- chat:

  An ellmer chat object. Defaults to
  [`ellmer::chat_anthropic()`](https://ellmer.tidyverse.org/reference/chat_anthropic.html)
  (requires `ANTHROPIC_API_KEY`). Any tool-capable ellmer provider
  works.

- dir:

  Run directory for checkpoints and all artifacts (reports, validation
  plots, model bundles). Defaults to a timestamped folder under
  `getOption("atlas.dir", ".atlas")`; set
  `options(atlas.dir = "~/atlas-runs")` in your `.Rprofile` to send
  every run somewhere of your choosing, or pass `dir` explicitly.

- verbose:

  Stream the agent's narration to the console.

- max_fix_rounds:

  How many automatic constraint-repair rounds to allow after the initial
  build.

- stopping_rounds:

  Stopping rule: give up on an iteration (adding candidate models, or a
  refinement loop like "keep improving the features") after this many
  consecutive attempts without improvement.

- stopping_tolerance:

  Stopping rule: an attempt only counts as an improvement if it beats
  the best validation metric so far by at least this relative fraction,
  between 0 and 1 - e.g. `0.05` for 5%.

- refine:

  After the winning algorithm is found (and constraints pass), keep
  iterating on its feature selection and engineering - one change per
  attempt, same validation scheme - until the stopping rules trigger
  (`stopping_rounds` consecutive attempts without a relative gain of at
  least `stopping_tolerance`). The refined model lands in the results as
  `<winner>_refined`, alongside the original.

- validate:

  Produce reviewable validation output for the winning model (gain,
  calibration, grouped residuals, one-ways, PDPs) as interactive HTML
  files in the run directory, via the `modelblueprint` package. Silently
  skipped when `modelblueprint` isn't installed.

- exclude:

  Columns the models must not use - because they won't be available at
  prediction time in deployment, or they leak the outcome. They are
  removed from the data before the agent sees it. Predictors that
  survive are additionally screened with
  [`atlas_leakage_screen()`](https://mattyoreilly.github.io/Atlas/reference/atlas_leakage_screen.md),
  and the agent is told to confirm anything suspicious with you before
  using it.

- autonomous:

  Run with no human in the loop: the agent states its plan and proceeds
  instead of waiting for approval, and never asks questions. Combine
  with a generous `n_models`/`stopping_rounds` and `test_prop` for
  unattended experimentation runs - e.g.
  `atlas(d, "y", autonomous = TRUE, n_models = 10, stopping_rounds = 8, test_prop = 0.2)` -
  where the agent iterates keep/discard experiments and the survivors
  are judged on the held-out test set at the end.

- test_prop:

  Proportion of rows (0 to \<1) to hold out as a final test set the
  agent never sees. After the run, Atlas itself evaluates every final
  model on it (RMSE for continuous outcomes, accuracy otherwise) - a
  ranking the agent can't overfit. Reported as `test_leaderboard` in the
  results and saved to `test_leaderboard.csv` in the run directory. `0`
  (default) disables the split.

- compact_at:

  Token budget for the conversation. Past this many input tokens the
  context is compacted: the transcript is archived to the run directory
  and the agent is re-oriented with a briefing built from the session
  state (models, leaderboard, code count) at no extra LLM cost. Keeps
  long runs inside the context window and stops them paying to re-read
  their own history. `Inf` disables. The total cost of a session is
  reported as `cost` in the results and by
  [`print()`](https://rdrr.io/r/base/print.html).

- max_steps, max_runtime:

  Hard budgets, mechanically enforced (unlike the stopping rules, which
  the agent applies itself): the maximum number of code executions and
  wall-clock seconds for the session. The agent is warned in tool
  results as a budget nears exhaustion; past the limit, code execution
  is refused and it must finalise from what it has. `Inf` (default)
  disables. Recommended for `autonomous` runs.

## Value

An object of class `atlas`: list with `models` (named list of fitted
models), `leaderboard` (data.frame of validation metrics),
`test_leaderboard` (held-out test metrics, when `test_prop > 0`),
`report` (markdown, how each model was built), `code` (every code chunk
the agent ran), `dir`, and `session` (the live
[atlas_session](https://mattyoreilly.github.io/Atlas/reference/atlas_session.md),
for follow-ups via `$tell()`).

## Examples

``` r
if (FALSE) { # \dontrun{
res <- atlas(mtcars, "mpg", n_models = 3,
             goal = "prioritise interpretability",
             constraints = list(
               uses_wt = con_uses("wt"),
               mono_hp = con_monotone("hp", "decreasing"),
               no_leak = "qsec is measured after the fact; never use it"
             ))
res                          # leaderboard, constraint status, report
res$constraints              # compliance table: model x constraint
predict(res$models[[1]], head(mtcars))
cat(res$code, sep = "\n\n")  # the full script the agent ran
res$session$tell("why did the winning model win?")
} # }
```
