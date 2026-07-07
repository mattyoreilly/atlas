# Define a hard constraint on the models Atlas builds

Constraints carry domain knowledge into the build: the description is
put in front of the agent as a hard requirement, and if `check` is
supplied the constraint is *verified* — every final model is tested
after the build, and violations are sent back to the agent to fix (see
`max_fix_rounds` in
[`atlas()`](https://mattyoreilly.github.io/Atlas/reference/atlas.md)).
Plain strings passed to `constraints` are shorthand for
`constraint(<string>)`: enforced via instructions only.

## Usage

``` r
constraint(description, check = NULL)
```

## Arguments

- description:

  What must hold, in plain language. The agent reads this.

- check:

  Optional verification: `function(model, data)` returning `TRUE` if the
  constraint holds, or a string describing the violation (`FALSE` also
  counts as a violation). Errors count as violations too, so a check may
  simply [`stop()`](https://rdrr.io/r/base/stop.html) on bad models.

## Value

An `atlas_constraint`.

## See also

[`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md),
[`con_monotone()`](https://mattyoreilly.github.io/Atlas/reference/con_monotone.md)
for ready-made checks.

## Examples

``` r
constraint("never use the `id` column; it is a row identifier")
#> [prompt-only]     never use the `id` column; it is a row identifier

constraint(
  "predictions must never be negative",
  check = function(model, data) {
    p <- predict(model, newdata = data)
    if (all(p >= 0)) TRUE else "some predictions are negative"
  }
)
#> [machine-checked] predictions must never be negative
```
