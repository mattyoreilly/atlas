# A persistent, resumable model-building session

An `atlas_session` wraps an LLM agent, an R working environment holding
your data, and a run directory on disk. The agent builds models by
executing R code; every code chunk and conversation turn is checkpointed
to the run directory, so a session survives crashes and R restarts (see
[`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md)).
The agent pauses and asks for your approval or input via the console
when it needs a decision (interactive sessions only).

## Run directory contents

- `data.rds`, `meta.rds` - inputs, so the session can be rebuilt cold

- `code.R` / `code.rds` - every code chunk the agent executed

- `turns.rds` - the full conversation

- `report.md`, `leaderboard.csv`, `models.rds` - final artifacts

## Public fields

- `chat`:

  The underlying ellmer chat object.

- `env`:

  Environment the agent's code runs in (`data` lives here).

- `dir`:

  Run directory used for checkpoints and artifacts.

- `code`:

  Character vector of every code chunk executed so far.

- `test_data`:

  Held-out test rows (when `test_prop > 0`); never placed in the agent's
  environment.

- `tally`:

  Live experiment tally: one row per recorded attempt (`attempt`,
  `name`, `metric`, `value`, `best`, `verdict`), kept by atlas from the
  agent's `record_attempt` calls and persisted to `tally.csv` in the run
  directory.

## Methods

### Public methods

- [`atlas_session$new()`](#method-atlas_session-initialize)

- [`atlas_session$build()`](#method-atlas_session-build)

- [`atlas_session$check()`](#method-atlas_session-check)

- [`atlas_session$tell()`](#method-atlas_session-tell)

- [`atlas_session$results()`](#method-atlas_session-results)

- [`atlas_session$add_budget()`](#method-atlas_session-add_budget)

- [`atlas_session$compact()`](#method-atlas_session-compact)

- [`atlas_session$checkpoint()`](#method-atlas_session-checkpoint)

- [`atlas_session$print()`](#method-atlas_session-print)

- [`atlas_session$clone()`](#method-atlas_session-clone)

------------------------------------------------------------------------

### `atlas_session$new()`

Create a session.

#### Usage

    atlas_session$new(
      data,
      outcome,
      n_models = 3,
      goal = NULL,
      constraints = NULL,
      chat = NULL,
      dir = NULL,
      on_ask = NULL,
      display = c("console", "markdown"),
      stopping_rounds = 3,
      stopping_tolerance = 0.05,
      exclude = NULL,
      interject = NULL,
      autonomous = FALSE,
      test_prop = 0,
      compact_at = 1e+05,
      max_steps = Inf,
      max_runtime = Inf
    )

#### Arguments

- `data`:

  A data.frame.

- `outcome`:

  Name of the outcome column (string).

- `n_models`:

  How many final candidate models to build.

- `goal`:

  Optional extra instructions for the agent, e.g. "prioritise
  interpretability" or a full custom brief.

- `constraints`:

  Domain knowledge as hard requirements: a list of strings and/or
  [`constraint()`](https://mattyoreilly.github.io/Atlas/reference/constraint.md)
  objects (see also
  [`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md),
  [`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md)).
  Machine-checked constraints are verified against every final model.

- `chat`:

  An ellmer chat object. Defaults to
  [`ellmer::chat_anthropic()`](https://ellmer.tidyverse.org/reference/chat_anthropic.html).
  Any ellmer provider works.

- `dir`:

  Run directory for checkpoints and all output (reports, validation
  plots, model bundles). Defaults to a timestamped folder under
  `getOption("atlas.dir", ".atlas")` - set
  `options(atlas.dir = "~/atlas-runs")` once to send every run to a
  location of your choosing, or pass `dir` explicitly per run.

- `on_ask`:

  Optional handler for the agent's questions: `function(question)`
  returning the user's answer as a string. When `NULL` (default),
  questions are asked in the console (interactive sessions) or answered
  with "use your best judgment" (scripts). Used by
  [`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md)
  to route questions to the browser.

- `display`:

  How verbose progress is formatted: `"console"` (cli rules and colours)
  or `"markdown"` (fenced code blocks, for front-ends that render the
  stream as markdown, like
  [`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md)).

- `stopping_rounds`:

  Stopping rule: give up on an iteration (adding candidates, or a
  refinement loop) after this many consecutive attempts without
  improvement.

- `stopping_tolerance`:

  Stopping rule: an attempt only counts as an improvement if it beats
  the best validation metric so far by at least this relative fraction,
  between 0 and 1 (e.g. `0.05` for 5%).

- `exclude`:

  Columns the models must not use (not available at prediction time, or
  leakage). They are removed from the data before the agent ever sees
  it - the strongest possible guarantee.

- `interject`:

  Optional `function()` polled after every tool call. Return a string to
  interrupt the agent with a message mid-build (it is delivered with its
  next tool result, marked as highest priority); return `NULL` when
  there is nothing to say. Used by
  [`atlas_app()`](https://mattyoreilly.github.io/Atlas/reference/atlas_app.md)'s
  "Send now" box; front-ends typically read the message from a file or
  queue.

- `autonomous`:

  Run without a human: the agent states its plan and proceeds instead of
  asking for approval, and never calls `ask_user`.

- `test_prop`:

  Proportion of rows (0 to \<1) to hold out as a final test set **the
  agent never sees**. Final models are evaluated on it by Atlas itself
  after the run (`$results()$test_leaderboard`), so the comparison can't
  be gamed by overfitting the agent's own validation scheme. `0`
  (default) disables the split.

- `compact_at`:

  Token budget for the conversation. When the context grows past this
  many input tokens, it is compacted before the next message: the
  transcript is archived to the run directory, the window is cleared,
  and the agent is re-oriented with a briefing built from the session
  state (no extra LLM call). Long runs stay inside the model's context
  window and stop paying to re-read their own history. Set to `Inf` to
  disable.

- `max_steps`:

  Hard budget: the maximum number of code executions the agent gets in
  this session. Unlike the stopping rules (which the agent applies
  itself), this is mechanically enforced - past the limit the
  `run_r_code` tool refuses to execute and instructs the agent to
  finalise from what it has. `Inf` (default) disables.

- `max_runtime`:

  Hard budget: wall-clock seconds for this session process, enforced the
  same way as `max_steps`. Timing restarts on
  [`atlas_resume()`](https://mattyoreilly.github.io/Atlas/reference/atlas_resume.md).
  `Inf` (default) disables.

------------------------------------------------------------------------

### `atlas_session$build()`

Run the full model-building loop. Streams the agent's narration and asks
for approval/input in the console when needed. After the build,
machine-checked constraints are verified against every final model;
violations are sent back to the agent to fix, up to `max_fix_rounds`
times.

#### Usage

    atlas_session$build(
      verbose = TRUE,
      max_fix_rounds = 2,
      refine = TRUE,
      validate = TRUE
    )

#### Arguments

- `verbose`:

  Show the agent's narration, code, and output live.

- `max_fix_rounds`:

  How many constraint-repair rounds to allow.

- `refine`:

  After the winning algorithm is found (and constraints pass), iterate
  on its feature selection and engineering - one change per attempt,
  same validation scheme - until the session's stopping rules trigger
  (`stopping_rounds` attempts without a `stopping_tolerance` gain). The
  refined model is added to the results alongside the original.

- `validate`:

  Produce reviewable validation output (gain, calibration, grouped
  residuals, one-ways, PDPs) for the winning model as interactive HTML
  files in the run directory. Needs the `modelblueprint` package;
  silently skipped when it isn't installed.

#### Returns

An `atlas` results object (invisibly); see `$results()`.

------------------------------------------------------------------------

### `atlas_session$check()`

Verify all machine-checked constraints against the current
`atlas_models`.

#### Usage

    atlas_session$check()

#### Returns

A data.frame with one row per model x constraint: `model`, `constraint`,
`passed` (`NA` for prompt-only constraints), `detail`.

------------------------------------------------------------------------

### `atlas_session$tell()`

Send a follow-up instruction or question to the agent in the same
context ("why did you drop cyl?", "add a 4th model", ...).

#### Usage

    atlas_session$tell(text, verbose = TRUE)

#### Arguments

- `text`:

  What to say to the agent.

- `verbose`:

  As in `$build()`.

#### Returns

The agent's reply (invisibly).

------------------------------------------------------------------------

### `atlas_session$results()`

Collect results: the fitted models, the leaderboard, the report, and the
full code trail.

#### Usage

    atlas_session$results()

#### Returns

An object of class `atlas`: list with `models` (named list of fitted
models), `leaderboard` (data.frame of validation metrics), `report`
(markdown), `code`, `dir`, and `session` (this object).

------------------------------------------------------------------------

### `atlas_session$add_budget()`

Grant the agent more mechanical budget. The hard caps (`max_steps`,
`max_runtime`) protect unattended runs, but they also bind follow-up
`$tell()` calls on a finished session - top the budget up explicitly
when you want more work done: `res$session$add_budget(steps = 25)`.

#### Usage

    atlas_session$add_budget(steps = 0, seconds = 0)

#### Arguments

- `steps`:

  Additional code executions to allow.

- `seconds`:

  Additional wall-clock seconds to allow.

------------------------------------------------------------------------

### `atlas_session$compact()`

Compact the conversation to save tokens: archive the transcript to the
run directory, clear the context window, and re-orient the agent with a
state briefing on the next message. The R environment (models, data) and
code log are untouched - they are the durable memory. Called
automatically when the context exceeds `compact_at`; call it yourself
before a long follow-up to start from a lean window.

#### Usage

    atlas_session$compact()

------------------------------------------------------------------------

### `atlas_session$checkpoint()`

Write the current code log and conversation to the run directory. Called
automatically after every tool call and reply.

#### Usage

    atlas_session$checkpoint()

------------------------------------------------------------------------

### `atlas_session$print()`

Print a short status line.

#### Usage

    atlas_session$print(...)

#### Arguments

- `...`:

  Ignored.

------------------------------------------------------------------------

### `atlas_session$clone()`

The objects of this class are cloneable with this method.

#### Usage

    atlas_session$clone(deep = FALSE)

#### Arguments

- `deep`:

  Whether to make a deep clone.

## Examples

``` r
if (FALSE) { # \dontrun{
s <- atlas_session$new(mtcars, outcome = "mpg", n_models = 3)
res <- s$build()          # agent works, asking for approval as needed
res                       # leaderboard + per-model report
s$tell("try a model with only 3 predictors as a 4th candidate")

# later, in a new R session:
s <- atlas_resume(".atlas/20260703-141500")
} # }
```
