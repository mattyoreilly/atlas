# Constraint: predictions must be monotonic in a variable

Machine-checked, model-agnostic (ICE-style): for a sample of observed
rows, the variable is swept over its observed range with everything else
held fixed, and predictions must move in the stated direction every
time.

## Usage

``` r
con_monotone(
  var,
  direction = c("increasing", "decreasing"),
  tol = 1e-08,
  n_grid = 25,
  n_rows = 20
)
```

## Arguments

- var:

  Column name (numeric) the response must be monotonic in.

- direction:

  `"increasing"` or `"decreasing"`.

- tol:

  Tolerance for tiny numeric wiggles.

- n_grid, n_rows:

  Size of the sweep grid and number of rows tested.

## Value

An `atlas_constraint`.

## Details

Monotonicity is non-strict, so a model that does not use `var` at all
passes trivially (a flat response is monotone). This makes the
constraint conditional - "if the model responds to `var`, the effect
must be monotone" - without forcing the variable in. Pair with
[`con_uses()`](https://mattyoreilly.github.io/Atlas/reference/con_uses.md)
when the variable must also be used.

## Examples

``` r
mono <- con_monotone("wt", "decreasing")
mono$check(lm(mpg ~ wt, mtcars), mtcars)          # TRUE: linear, negative
#> [1] TRUE
con_monotone("wt", "increasing")$check(lm(mpg ~ wt, mtcars), mtcars)
#> [1] "predictions are not monotonically increasing in `wt` (violated with other predictors held at row 1's values)"

if (FALSE) { # \dontrun{
atlas(df, "price", constraints = list(
  mono_sqft = con_monotone("sqft", "increasing")
))
} # }
```
