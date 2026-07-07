# Unattended runs

The interactive workflow assumes you’re at the console to approve the
plan and answer questions. This vignette covers the other mode: give the
agent a real modeling problem and let it experiment on its own -
overnight, inside a script, on a schedule - trying changes, keeping what
improves and discarding what doesn’t, with the survivors judged at the
end on data the agent never touched.

The complete recipe:

``` r

library(atlas)

res <- atlas(claims, "severity",
  autonomous         = TRUE,   # never waits, never asks
  n_models           = 10,     # ceiling on candidates
  stopping_rounds    = 8,      # keep going until 8 flat attempts in a row
  stopping_tolerance = 0.02,   # <2% relative gain doesn't count
  max_steps          = 300,    # hard cap on code executions
  max_runtime        = 8 * 3600,  # and on wall-clock time
  test_prop          = 0.2)    # final judgment on unseen rows

res$test_leaderboard
```

Each piece of that call earns its place. The rest of this vignette
explains them.

## Autonomy

`autonomous = TRUE` rewrites the agent’s human-in-the-loop contract. The
plan-approval gate becomes “state the plan and proceed”; monotone
constraints the agent considers clearly right on domain grounds are
applied directly (and noted in the narration) instead of proposed for
approval; and the agent is told flatly that no user exists - it must
never call its `ask_user` tool, and must record every judgment call in
its narration and report instead.

Everything else about the run is unchanged: same lifecycle, same
checkpointing, same constraint verification. An autonomous run with
`verbose = FALSE` in an `Rscript` is silent and leaves its entire story
in the run directory (`report.md`, `code.R`, `leaderboard.csv`).

## Two kinds of stopping

An unattended run needs an answer to “when do you stop?”, and atlas
deliberately gives two, with different trust models.

**Statistical stopping - applied by the agent.** `stopping_rounds` and
`stopping_tolerance` (H2O users will recognise the names) define
convergence: an attempt counts as an improvement only if it beats the
best validation metric so far by at least `stopping_tolerance`
(relative), and an iteration ends after `stopping_rounds` consecutive
attempts without one. These govern both candidate building and the
winner-refinement loop, and because one improvement resets the count, a
long run can work through flat stretches. The agent applies these rules
itself and must state in the report which one fired.

**Mechanical stopping - enforced by atlas.** `max_steps` (code
executions) and `max_runtime` (wall-clock seconds) are budgets the agent
cannot talk its way past. They are disclosed in its instructions up
front; warnings start appearing in tool results once 80% of a budget is
spent (“240 of 300 code executions used - prioritise finalising”); and
past the limit the execution tool refuses outright - the code does not
run, and the agent is told to write its report from what already exists.
The refinement and validation phases are skipped rather than started if
the budget is already gone.

Use them together: generous statistical rules so the agent explores, and
a mechanical ceiling so “overnight” can’t become “over the weekend”.

The budget binds the whole session, follow-up `$tell()` calls included -
a finished run with nothing left in the tank will refuse further work.
That is deliberate (a cap you can talk your way past is not a cap), and
the remedy is explicit: grant more, then continue.

``` r

res$session$add_budget(steps = 25)
res$session$tell("remove the worst predictor and re-evaluate")
```

## The live tally

Every model and every tweak is scored the moment it is evaluated. The
agent must call its `record_attempt` tool after each attempt, and
atlas - not the agent - keeps the ledger: it compares the result against
the best so far (using `stopping_tolerance`), prints a one-line tally,
and returns a mechanical verdict the agent is instructed to obey:

    [tally #7 | gbm_depth3: rmse = 2.412 | best: glm_gamma = 2.380 | flat: 2/8 -> DISCARD]

`KEEP` means the attempt is the new best; `DISCARD` means revert the
change completely - if it didn’t improve on current performance, it
goes. The flat-attempt counting is mechanical too: when
`stopping_rounds` consecutive attempts fail to improve, the verdict says
so in capitals and tells the agent to stop iterating and finalise. The
full tally is persisted to `tally.csv` as it grows, returned as
`res$tally`, and summarised by `print(res)`.

## Steering a run that is already going

Autonomy doesn’t mean you can’t speak. From any other R session or
terminal, send the run a message:

``` r

atlas_message("~/runs/severity",
              "focus on the gamma GLM family; stop trying trees")
```

It is delivered with the agent’s next code execution, marked as its
highest-priority instruction; the agent acknowledges it and adjusts
course. “Focus on gradient boosting”, “change the feature engineering
for income”, “stop tuning and finalise” - anything you would say over a
colleague’s shoulder. Messages that arrive after the run has finished
are never picked up; resume and `$tell()` instead.

## The protected test set

`test_prop` is the piece that makes an autonomous run trustworthy.
Before the agent sees anything, atlas holds out that proportion of rows
(deterministically - the same data gives the same split). The agent is
told the test set exists and that final models will be judged on it, but
the rows never enter its environment: it cannot peek, tune against them,
or leak them into feature engineering.

When the run ends, **atlas itself** - plain R, no LLM - evaluates every
model in the results on the held-out rows: RMSE for continuous outcomes,
accuracy otherwise, with models that fail to predict scored `NA` rather
than sinking the run. The ranking lands in `res$test_leaderboard`, in
`test_leaderboard.csv`, and in `print(res)` right beside the agent’s own
validation leaderboard - so you can see at a glance whether the agent’s
sense of “better” survived contact with unseen data.

``` r

res$leaderboard        # what the agent believed, from its validation scheme
res$test_leaderboard   # what the held-out data says; this one is final
```

## Token stewardship

A hundred-experiment run would ordinarily re-read its own growing
history on every step - quadratic token cost, and eventually a
context-window overflow. atlas avoids both because the conversation was
never the real memory: the R environment holds the models and the run
directory holds the code log.

Past `compact_at` input tokens (default 100,000), the conversation is
compacted before the next message: the transcript is archived to the run
directory (`turns-archive-01.rds`, …), the window is cleared, and the
agent is re-oriented with a briefing built deterministically from
session state - current models, the leaderboard, how many chunks have
run. No summarising LLM call, nothing invented. Long runs therefore pay
roughly constant tokens per experiment.

Cost stays visible throughout: every results object carries the
session’s cumulative dollar `cost`, and `print(res)` shows it.

## Checking in on a run

Everything is checkpointed as it happens, so an unattended run can be
inspected - or picked up - at any time from another R session:

``` r

# from anywhere, while the run is going or after it crashed:
readLines(file.path(dir, "report.md"))     # the story so far
read.csv(file.path(dir, "leaderboard.csv"))

# take over interactively:
s <- atlas_resume(dir)
s$tell("stop exploring tree models; focus on the GLM family")
```

Resuming replays the recorded code log against the saved data, so the
session comes back with every fitted object intact - see
[`vignette("sessions")`](https://mattyoreilly.github.io/Atlas/articles/sessions.md)
for the mechanics.

## What autonomy doesn’t change

The guard-rails of the interactive mode still hold. Constraints are
still verified by atlas and repaired on violation. Excluded columns
still never reach the agent. The leakage screen still runs, and in
autonomous mode a flagged predictor with no user to vouch for it should
be treated with suspicion - the conservative move is to `exclude`
anything doubtful before an unattended run rather than leaving the
judgment to the agent.
