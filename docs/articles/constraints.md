# Domain knowledge and constraints

An instruction to an LLM is a request; a constraint should be a
guarantee. Atlas draws that line explicitly. Soft preferences
(“prioritise interpretability”) go in `goal` and shape the agent’s
choices. Hard requirements go in `constraints`, and any constraint that
can be tested in code is *verified* — by Atlas, not the agent — against
every final model.

Enforcement happens at three points:

1.  **Up front:** constraints appear in the agent’s task as numbered
    hard requirements, with an instruction to design for them from the
    start (pick a monotone model form; don’t bolt monotonicity on
    afterwards).
2.  **During the build:** the agent has a `check_constraints` tool to
    verify its own work before declaring the build done.
3.  **After the build:** Atlas independently runs every machine check
    against every model in the results. Violations are formatted into a
    repair prompt and sent back — the agent must refit until the checks
    pass or `max_fix_rounds` is exhausted, and the outcome is reported
    either way.

## Three ways to write a constraint

``` r

library(atlas)

res <- atlas(mtcars, "mpg", n_models = 2, constraints = list(
  # 1. built-in helpers: machine-checked, model-agnostic
  uses_wt = con_uses("wt"),
  mono_hp = con_monotone("hp", "decreasing"),

  # 2. custom check: function(model, data) -> TRUE or a violation message
  non_neg = constraint(
    "predicted mpg must never be negative",
    check = function(model, data) {
      p <- predict(model, newdata = data)
      if (all(p >= 0)) TRUE else "some predictions are negative"
    }
  ),

  # 3. plain string: enforced via instructions only
  no_leak = "qsec is measured after the fact; never use it as a predictor"
))
```

Prefer a `check` whenever the rule is testable; reserve strings for
rules only the agent can honour. A check may also
[`stop()`](https://rdrr.io/r/base/stop.html) — errors count as
violations, with the error message as the detail.

## The built-in helpers

Both helpers are model-agnostic: they need only
`predict(model, newdata = <data.frame>)` to work, and Atlas tells the
agent every final model must support exactly that.

`con_uses(var)` asserts the model actually *uses* a variable. The check
scrambles the column and compares predictions: if they don’t move, the
variable isn’t contributing. No formula inspection, so it works
identically for a `glm`, a random forest, or a wrapped model object.

`con_monotone(var, direction)` asserts predictions are monotone in a
variable, ICE-style: for a sample of observed rows, the variable is
swept across its range with everything else held fixed, and every step
must move in the stated direction (within `tol`).

Monotonicity is non-strict, and that is a feature: a model that ignores
the variable has a flat — hence monotone — response, and passes. So
[`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md)
alone means “*if* the model responds to `hp`, the effect must be
decreasing”. Pair it with
[`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md)
to also force the variable in:

``` r

# conditional: monotone if used, but may be dropped
constraints = list(mono_hp = con_monotone("hp", "decreasing"))

# mandatory and monotone
constraints = list(uses_hp = con_uses("hp"),
                   mono_hp = con_monotone("hp", "decreasing"))
```

## Custom check patterns

Any property you can compute from `(model, data)` can be a guarantee:

``` r

# a performance floor
min_r2 <- constraint(
  "in-sample R-squared must be at least 0.7",
  check = function(model, data) {
    r2 <- cor(predict(model, newdata = data), data$mpg)^2
    if (r2 >= 0.7) TRUE else sprintf("R-squared is %.2f", r2)
  }
)

# bounded predictions
in_range <- constraint(
  "predictions must stay within the observed outcome range",
  check = function(model, data) {
    p <- predict(model, newdata = data)
    if (all(p >= min(data$mpg) & p <= max(data$mpg))) TRUE
    else "predictions leave the observed range"
  }
)

# parity across a group
fair_gap <- constraint(
  "mean absolute error must be within 1 unit across am groups",
  check = function(model, data) {
    err <- abs(data$mpg - predict(model, newdata = data))
    gap <- abs(diff(tapply(err, data$am, mean)))
    if (gap <= 1) TRUE else sprintf("MAE gap across am is %.2f", gap)
  }
)
```

## Excluding features, and catching leakage

Constraints govern *how* variables are used; sometimes the right answer
is that a variable must not exist at all — it won’t be available at
prediction time in deployment, or it leaks the outcome. That is
`exclude`, and it is deliberately blunt: excluded columns are dropped
from the data **before the agent ever sees it**, which no instruction
can match for certainty.

``` r

res <- atlas(claims, "severity",
             exclude = c("settlement_amount",   # known only after the outcome
                         "claim_ref"))          # an ID; useless in deployment
```

The surviving predictors are screened automatically with
[`atlas_leakage_screen()`](https://mattyoreilly.github.io/Atlas/reference/atlas_leakage_screen.md):
a fast univariate check that flags any column which alone explains
almost all of the outcome (R² ≥ 0.95 by default) — the classic signature
of a column derived from, or recorded after, the target. Flagged columns
are listed in the agent’s brief with an order to confirm each one with
you before relying on it. The screen is also useful standalone, before
any modeling:

``` r

atlas_leakage_screen(claims, "severity")
#>            variable    r2 flagged
#>   settlement_amount 0.998    TRUE
#>            exposure 0.310   FALSE
```

Being univariate, the screen catches copy-and-derived-column leakage,
not leakage that only emerges in combination — that is what the agent’s
own vigilance instructions and your `exclude` list are for.

## Constraints the agent suggests

Some monotone constraints are so obviously right that forgetting them is
the only failure mode — price should not fall as floor area grows.
During exploration, Atlas is instructed to think about which predictors
should plausibly have monotone effects, and to include any such
suggestions — variable, direction, one-line rationale — in the plan it
asks you to approve. Each suggestion you approve is added through the
agent’s `add_monotone_constraint` tool and becomes a real,
machine-checked constraint: verified, repaired on violation, and
persisted with the session. Nothing is added without your approval.

## Constraints from natural language

[`extract_constraints()`](https://mattyoreilly.github.io/Atlas/reference/extract_constraints.md)
turns a plain-language brief into constraint objects, mapping to machine
checks wherever it recognises a checkable rule:

``` r

cons <- extract_constraints(
  "weight must be in the model; predictions can never go up as horsepower
   rises; qsec is measured after the fact, never use it",
  data = mtcars
)
cons
#> $uses_wt
#> [machine-checked] The variable `wt` must be used as a predictor.
#> $mono_hp
#> [machine-checked] Predictions must be monotonically decreasing in `hp`.
#> $no_qsec
#> [prompt-only]     Never use qsec as a predictor.

res <- atlas(mtcars, "mpg", constraints = cons)
```

Parsing intent is a judgment call, so the function returns the list for
you to inspect and edit rather than feeding it straight into a build.
Pass `data` to validate column names; anything unmappable (an unknown
column, a monotone rule without a direction) falls back to prompt-only
enforcement instead of becoming a broken check.

## Reading the compliance table

`res$constraints` has one row per model × machine-checked constraint,
plus one row per prompt-only constraint:

- `passed = TRUE` / `FALSE` — the check ran; `detail` explains any
  failure.
- `passed = NA` — prompt-only: enforced through instructions, not
  verifiable.

`print(res)` surfaces failures loudly, and a session’s current state can
be re-checked at any time with `res$session$check()`.
