
# atlas

Atlas builds models for you, and shows its work. Give it a data frame
and a target; an LLM agent (via [ellmer](https://ellmer.tidyverse.org))
explores the data, proposes a modeling plan for your approval, then
writes and runs R code to fit, compare, and refine candidate models. You
get back fitted models ready for `predict()`, a leaderboard, a written
report - and, because the agent works by writing R, the complete script
of everything it did.

Three ideas separate atlas from “ask a chatbot for model code”:

- **Domain knowledge is enforced, not suggested.** Constraints like
  “`wt` must be used” or “predictions must never rise with horsepower”
  are machine-verified against every final model, and violations are
  sent back to the agent to fix.

- **Sessions are persistent.** Every code chunk and conversation turn is
  checkpointed to disk as it happens. A crash, a restart, or a
  deliberate interruption loses nothing - resume and keep going.

- **Your data stays on your machine.** The LLM sees column names, types,
  and printed summaries, never the rows. All fitting happens locally in
  your R session.

## Installation

atlas is not yet on CRAN. Install the development version from
[GitHub](https://github.com/mattyoreilly/Atlas):

``` r
# install.packages("pak")
pak::pkg_install("mattyoreilly/atlas")
```

You also need an API key for an LLM provider. atlas defaults to
Anthropic: run `usethis::edit_r_environ()`, add a line
`ANTHROPIC_API_KEY=sk-ant-...`, save, and restart R. Any tool-capable
ellmer provider works via the `chat` argument - OpenAI, Gemini, Bedrock,
or a local model through Ollama.

## Usage

``` r
library(atlas)

res <- atlas(mtcars, outcome = "mpg", goal = "prioritise interpretability")
```

The agent narrates as it works. It profiles the data (flagging suspected
target leakage), proposes a plan - model families chosen to match the
outcome’s distribution, a seeded validation scheme, any monotone effects
it believes the domain implies - and **waits for your approval in the
console**. You can answer “yes”, or redirect it: “only linear models,
and don’t use qsec”. Then it builds up to `n_models` candidates,
compares them on held-out data, refines the winner’s features until
improvement stalls, verifies any constraints, and - with
[modelblueprint](https://mattyoreilly.github.io/modelblueprint/)
installed - writes a full validation workup (gain, calibration, grouped
residuals, one-ways, PDPs) to the run directory.

``` r
res               # leaderboard, constraint compliance, report, cost
res$models        # fitted models: predict(res$models$glm1, newdata)
res$code          # every line of R the agent ran, in order
res$session$tell("why did the refined model win?")   # keep talking
```

## How a build works

Every run walks the same six stages, and you hold the pen at stage 2:

1.  **Explore** - dimensions, types, missingness, the outcome’s
    distribution; automatic leakage screening.

2.  **Plan, then stop for you** - candidate families matched to the
    outcome’s distribution, a validation scheme, suggested monotone
    constraints. Approval is a conversation: whatever you type is folded
    into the plan.

3.  **Build** - up to `n_models` candidates, compared on held-out data.
    Every model and tweak is scored the moment it is evaluated: atlas
    keeps a live tally, compares against the best so far, and answers
    with a mechanical verdict the agent must obey - if it doesn’t
    improve, it goes.

        [tally #7 | gbm_depth3: rmse = 2.412 | best: glm_gamma = 2.380 | flat: 2/8 -> DISCARD]

4.  **Refine** - the winner’s features are iterated one change at a time
    until the stopping rules call convergence.

5.  **Verify** - machine-checked constraints run against every final
    model; violations trigger repair rounds.

6.  **Document** - report, leaderboard, reproducible script, validation
    plots, all in the run directory.

Two kinds of dial control how long this takes. The *statistical*
stopping rules (H2O-style names) run through the tally:
`stopping_rounds` consecutive attempts without improvement end an
iteration, gains below `stopping_tolerance` don’t count, and atlas does
the counting - the tally verdict tells the agent, in so many words, when
the rule has triggered. The *mechanical* budgets are enforced in code
and cannot be talked past: after `max_steps` code executions or
`max_runtime` seconds, the execution tool refuses to run anything more
and the agent must finalise with what it has. A finished session that is
out of budget refuses further `$tell()` calls before any tokens are
spent - grant more explicitly with `res$session$add_budget(steps = 25)`.

## Constraints

Pass hard requirements as a list. Strings are enforced through
instructions; constraint objects carry a `check` function that atlas
runs against every final model, feeding failures back to the agent for
repair:

``` r
res <- atlas(mtcars, "mpg", constraints = list(
  uses_wt = con_uses("wt"),                    # must actually use wt
  mono_hp = con_monotone("hp", "decreasing"),  # effect must be monotone
  no_leak = "qsec is measured after the fact; never use it"
))
res$constraints    # one row per model x constraint: passed, detail
```

Columns that won’t exist at prediction time don’t belong in the data at
all - `exclude` removes them before the agent ever sees it, and
`atlas_leakage_screen()` automatically flags predictors that alone
explain almost all of the outcome. See `vignette("constraints")`.

## Unattended runs

For hands-off experimentation - overnight, in a script, on a schedule -
set `autonomous = TRUE`: the agent states its plan and proceeds instead
of waiting for approval, iterating keep/discard experiments under the
stopping rules. Pair it with `test_prop` to hold out rows the agent
**never sees**; when the run ends, atlas itself evaluates every
surviving model on that test set, so the final ranking can’t be gamed by
overfitting the agent’s own validation scheme:

``` r
res <- atlas(claims, "severity",
             autonomous = TRUE,
             n_models = 10, stopping_rounds = 8,  # room to explore
             max_steps = 300,                     # hard cap, enforced in code
             test_prop = 0.2)                     # the ungameable judge

res$test_leaderboard   # held-out performance, best first
res$tally              # every attempt: KEEP / DISCARD, best-so-far
```

Autonomous doesn’t mean unreachable: steer a running build from any
other R session or terminal, and the message reaches the agent at its
next step as its highest-priority instruction:

``` r
atlas_message("~/atlas-runs/severity",
              "focus on the gamma GLM family; stop trying trees")
```

Long runs stay affordable: past a token budget (`compact_at`) the
conversation is compacted - transcript archived to disk, context
cleared, agent re-oriented from session state at no extra LLM cost - and
every results object reports the session’s total dollar `cost`. See
`vignette("autonomous")`.

## Sessions

`atlas()` is a one-call wrapper around an `atlas_session`, which lives
in the run directory as much as in memory: data, code log, conversation,
and artifacts (report, leaderboard, models, validation plots) are all on
disk, so sessions survive anything:

``` r
s <- atlas_resume(".atlas/20260703-141500")
s$tell("swap the elastic net for a GAM and re-compare")
```

Runs land in `.atlas/<timestamp>` by default; set
`options(atlas.dir = "~/atlas-runs")` to choose. See
`vignette("sessions")`.

## Limitations

- **Columns are the scaling limit, not rows.** Fitting is local, so a
  million rows just take the time they take - but the agent reasons
  about variables by name, and past a few dozen columns that reasoning
  degrades. Pre-select features for wide data.
- **Cost scales with agent steps**, not data size: more candidates, more
  repair rounds, more follow-ups mean more LLM calls. `print(res)` shows
  what a session cost.
- **The statistical stopping rules are agent-applied.** For guarantees,
  use the mechanical budgets (`max_steps`, `max_runtime`) - those are
  enforced by atlas, not the model.
- **An agent is not a statistician.** atlas verifies what you tell it to
  verify; judgment about what the model is *for* stays with you. Read
  the report, check `res$code`, and look at the validation output.

## Learn more

- `vignette("atlas")` - a full walkthrough: setup, the build lifecycle,
  what you get back, what it costs
- `vignette("constraints")` - encoding domain knowledge that can’t be
  ignored
- `vignette("sessions")` - persistence, resuming, steering mid-build,
  and token stewardship
- `vignette("autonomous")` - unattended runs with hard budgets and a
  protected test set
